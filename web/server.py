"""Loopback-only browser bridge to existing peon-code tmux panes."""
import json
import errno
import os
import re
import secrets
import signal
import subprocess
import sys
import shutil
import socket
import time
import tempfile
from bridge import panes, snapshot, tmux
from launch import arguments, open_browser, remote_ui, open_project, DEFAULT_PORT, REMOTE_CONFIG_DIR
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace
from urllib.parse import parse_qs, urlsplit

ROOT = Path(__file__).resolve().parent.parent
try:
    VERSION = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
except OSError:
    VERSION = ""
BUTTONS_DIR = ROOT / "buttons"
ASSETS = {"/": ("index.html", "text/html"), "/app.js": ("app.js", "text/javascript"),
          "/style.css": ("style.css", "text/css"),
          "/ansi.js": ("ansi.js", "text/javascript"),
          "/navigation.js": ("navigation.js", "text/javascript"),
          "/LICENSE": ("../LICENSE", "text/plain")}


def validate_button(data):
    name, description, prompt = data.get("name"), data.get("description"), data.get("prompt")
    name = name.strip(" ") if isinstance(name, str) else name
    if not isinstance(name, str) or not name or len(name) > 80 or not re.fullmatch(r"[A-Za-z0-9 '_-]+", name):
        raise ValueError("Name must use 1 to 80 letters, digits, spaces, apostrophes, hyphens, or underscores")
    if not isinstance(description, str) or len(description) > 500 or "\n" in description or "\r" in description:
        raise ValueError("Description must be a single line of at most 500 characters")
    if not isinstance(prompt, str) or not prompt.strip() or len(prompt) > 200000:
        raise ValueError("Prompt must contain text and be at most 200000 characters")
    description.encode("utf-8")
    prompt.encode("utf-8")
    button = dict(name=name, description=description, prompt=prompt)
    if "order" in data:
        if type(data["order"]) is not int or not 0 <= data["order"] <= 1000:
            raise ValueError("Order must be an integer from 0 to 1000")
        button["order"] = data["order"]
    return button


def read_buttons():
    result = []
    paths = list(BUTTONS_DIR.glob("*.md")) + list((config_dir() / "buttons").glob("*.md"))
    for path in paths:
        try:
            match = re.fullmatch(r"---\r?\n(?:order: ([^\r\n]*)\r?\n)?description: ([^\r\n]*)\r?\n(?:order: ([^\r\n]*)\r?\n)?---\r?\n([\s\S]*)", path.read_bytes().decode("utf-8"))
            if match:
                button = dict(name=path.stem, description=match[2], prompt=match[4])
                if match[1] is not None and match[3] is not None:
                    continue
                order = match[1] if match[1] is not None else match[3]
                if order is not None:
                    button["order"] = int(order)
                result.append(validate_button(button))
        except (ValueError, OSError):
            continue
    return sorted(result, key=lambda button: (button.get("order", 0), button["name"]))


def run_delivery(args, text, identity, timeout=20):
    environment = dict(os.environ, PEON_EXPECTED_IDENTITY=identity)
    process = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True, env=environment,
                               start_new_session=True)
    try:
        stdout, stderr = process.communicate(text, timeout=timeout)
    except subprocess.TimeoutExpired:
        # The Bash delivery guard and tmux child must stop before reporting failure.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.communicate()
        raise
    return subprocess.CompletedProcess(args, process.returncode, stdout, stderr)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass  # Tokens and agent content must not enter access logs.

    def respond(self, status, data, content_type="application/json"):
        body = json.dumps(data).encode() if content_type == "application/json" else data
        self.send_response(status)
        self.send_header("Content-Type", content_type + "; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", "default-src 'self'; frame-ancestors 'none'; base-uri 'none'")
        self.end_headers()
        self.wfile.write(body)

    def allowed(self, authenticated=False):
        if self.headers.get("Host") != self.server.address:
            self.respond(403, {"error": "Invalid host"})
            return False
        origin = self.headers.get("Origin")
        if origin and origin != self.server.origin:
            self.respond(403, {"error": "Invalid origin"})
            return False
        if authenticated and not secrets.compare_digest(self.headers.get("X-Peon-Token", "").encode("utf-8"), self.server.token.encode("ascii")):
            self.respond(403, {"error": "Invalid access token; reopen the launch URL"})
            return False
        return True

    def do_GET(self):
        parsed = urlsplit(self.path)
        if not self.allowed(parsed.path in ("/api/panes", "/api/buttons")):
            return
        if self.path in ASSETS:
            filename, mime = ASSETS[self.path]
            self.respond(200, (ROOT / "web" / filename).read_bytes(), mime)
        elif parsed.path == "/api/buttons":
            try:
                self.respond(200, read_buttons())
            except OSError as error:
                self.respond(503, {"error": str(error)})
        elif parsed.path == "/api/panes":
            query = parse_qs(parsed.query, keep_blank_values=True)
            target = query.get("pane", [None])[0]
            try:
                lines = int(query.get("lines", ["1000"])[0])
                # Capture at most 200000 history lines; raise this with the client limit if needed.
                if not 1000 <= lines <= 200000:
                    raise ValueError
            except ValueError:
                self.respond(400, {"error": "lines must be an integer from 1000 to 200000"})
                return
            cols = rows = None
            if "cols" in query or "rows" in query:
                try:
                    cols = int(query.get("cols", [""])[0])
                    rows = int(query.get("rows", [""])[0])
                    if not 20 <= cols <= 500 or not 5 <= rows <= 300:
                        raise ValueError
                except ValueError:
                    self.respond(400, {"error": "cols must be an integer from 20 to 500; rows must be an integer from 5 to 300"})
                    return
            try:
                current = panes(self.server.session)
                if cols is not None:
                    # Detached tmux windows default to 80x24. The browser shows one pane
                    # at a time, so stack full-width panes sized to its output area.
                    # A terminal client that attaches later sets the window size.
                    # With several browser tabs, the last poll sets the size.
                    for session in sorted({pane["session"] for pane in current}):
                        try:
                            window = session + ":agents"
                            if tmux("list-clients", "-t", "=" + session).strip():
                                if tmux("show-options", "-wv", "-t", window, "window-size").strip() == "manual":
                                    tmux("set", "-w", "-t", window, "-u", "window-size")
                                    tmux("select-layout", "-t", window, "main-vertical")
                                continue
                            count = len(tmux("list-panes", "-t", window).splitlines())
                            # Each pane's top border consumes one additional row.
                            height = min((rows + 1) * count, 10000)
                            if tmux("display-message", "-p", "-t", window, "#{window_width}x#{window_height}").strip() != f"{cols}x{height}":
                                tmux("resize-window", "-t", window, "-x", str(cols), "-y", str(height))
                                tmux("select-layout", "-t", window, "even-vertical")
                        except (OSError, subprocess.TimeoutExpired, subprocess.CalledProcessError):
                            errors = self.server.__dict__.setdefault("resize_errors", set())
                            if session not in errors:
                                errors.add(session)
                                print(f"Could not resize browser panes for {session!r}", file=sys.stderr)
                result = []
                for pane in current:
                    try:
                        captured = snapshot(pane, lines) if pane["id"] == target else snapshot(pane)
                        if captured is not None:
                            result.append(captured)
                    except subprocess.CalledProcessError:
                        continue
                self.respond(200, {"panes": result, "initial": self.server.initial, "version": VERSION})
            except (OSError, subprocess.TimeoutExpired) as error:
                self.respond(503, {"error": str(error)})
        else:
            self.respond(404, {"error": "Not found"})

    def do_POST(self):
        if not self.allowed(True):
            return
        if self.path not in ("/api/explain", "/api/send", "/api/dismiss", "/api/keys", "/api/buttons", "/api/open"):
            self.respond(404, {"error": "Not found"})
            return
        try:
            size = int(self.headers.get("Content-Length", "0"))
            limit = 2 * 1024 * 1024 if self.path == "/api/open" else 262144
            if not 0 < size <= limit or self.headers.get_content_type() != "application/json":
                raise ValueError("Expected JSON, at most " + ("2 MiB" if self.path == "/api/open" else "256 KiB"))
            data = json.loads(self.rfile.read(size))
            if self.path == "/api/open":
                directory, session = data.get("directory"), data.get("session", "")
                if not isinstance(directory, str) or not directory.strip() or len(directory) > 4096 or "\0" in directory:
                    raise ValueError("Project directory must contain 1 to 4096 characters without NUL")
                if not Path(directory).is_absolute() and not directory.startswith("~"):
                    raise ValueError("Project directory must be absolute or start with ~")
                if not isinstance(session, str):
                    raise ValueError("Session name must be text")
                if session.startswith("-") or any(ord(char) < 32 or ord(char) == 127 for char in session):
                    raise ValueError("Choose a valid SESSION name")
                config = None
                content = None
                if "config_name" in data or "config_text" in data:
                    if "config_name" not in data or "config_text" not in data:
                        raise ValueError("Config requires both config_name and config_text")
                    name, text = data["config_name"], data["config_text"]
                    if not isinstance(name, str) or not name.strip() or name in (".", "..") or "/" in name or "\\" in name or any(ord(char) < 32 or ord(char) == 127 for char in name):
                        raise ValueError("Config filename must be a basename without control characters")
                    name.encode("utf-8")
                    if not isinstance(text, str):
                        raise ValueError("Config text must be UTF-8 and at most 200 KiB")
                    content = text.encode("utf-8")
                    if len(content) > 200 * 1024:
                        raise ValueError("Config text must be UTF-8 and at most 200 KiB")
                try:
                    if content is not None:
                        uploads = Path.home() / REMOTE_CONFIG_DIR
                        uploads.mkdir(mode=0o700, parents=True, exist_ok=True)
                        with tempfile.NamedTemporaryFile(dir=uploads, prefix="team-", suffix=".conf", delete=False) as file:
                            config = Path(file.name)
                            file.write(content)
                    opened = open_project(SimpleNamespace(directory=directory, session=session, config=config), ROOT, timeout=300)
                except RuntimeError as error:
                    raise ValueError(str(error)) from error
                finally:
                    if config is not None:
                        config.unlink(missing_ok=True)
                self.server.session = None
                self.respond(200, {"session": opened})
                return
            if self.path == "/api/buttons":
                button = validate_button(data)
                directory = config_dir() / "buttons"
                directory.mkdir(parents=True, exist_ok=True)
                filename = button["name"] + ".md"
                try:
                    seed = BUTTONS_DIR / filename
                    if seed.exists() or seed.is_symlink():
                        raise FileExistsError
                    with (directory / filename).open("x", encoding="utf-8", newline="\n") as file:
                        order = "order: " + str(button["order"]) + "\n" if "order" in button else ""
                        file.write("---\n" + order + "description: " + button["description"] + "\n---\n" + button["prompt"])
                except FileExistsError:
                    self.respond(409, {"error": "A button with this name already exists"})
                    return
                self.respond(200, read_buttons())
                return
            if self.path == "/api/dismiss":
                session = data.get("session")
                if not isinstance(session, str) or not session or not any(p["session"] == session for p in panes(self.server.session)):
                    raise ValueError("Session changed or closed; refresh before closing")
                result = subprocess.run([str(ROOT / "peon-code.sh"), "dismiss", session],
                                        stdin=subprocess.DEVNULL, capture_output=True, text=True,
                                        timeout=10, start_new_session=True)
                message = (result.stdout + result.stderr).strip() or ("Session closed" if result.returncode == 0 else "Could not close session")
                self.respond(200 if result.returncode == 0 else 409,
                             {"message" if result.returncode == 0 else "error": message})
                return
            pane, text, identity = data.get("pane"), data.get("text"), data.get("identity")
            append = data.get("append", False)
            if self.path == "/api/send" and not isinstance(append, bool):
                raise ValueError("append must be a boolean")
            if self.path == "/api/keys":
                key = data.get("key")
                if key not in ("Tab", "Up", "Down", "Enter", "Escape", "Backspace"):
                    raise ValueError("Allowed keys: Tab, Up, Down, Enter, Escape, Backspace")
                text = ""
            elif not isinstance(text, str) or not text.strip():
                raise ValueError("Select or enter some text first")
            # ponytail: one send at a time; use per-pane locks if concurrent delivery matters.
            with self.server.send_lock:
                target = next((p for p in panes(self.server.session) if p["id"] == pane and p.get("identity") == identity), None)
                if not isinstance(identity, str) or target is None:
                    raise ValueError("Agent changed or closed; refresh before sending")
                action = "key" if self.path == "/api/keys" else "explain" if self.path == "/api/explain" else "send"
                args = [str(ROOT / "peon-code.sh"), action]
                if action == "send" and append:
                    args.append("--append")
                if action == "key" and key == "Enter":
                    args.append("--submit")
                args.append(pane)
                if action == "key":
                    args.append("BSpace" if key == "Backspace" else key)
                elif action == "send":
                    args.append("-")
                result = run_delivery(args, text, identity)
            message = (result.stdout + result.stderr).strip() or ("Sent" if result.returncode == 0 else "Could not send; check the agent pane")
            self.respond(200 if result.returncode == 0 else 409,
                         {"message" if result.returncode == 0 else "error": message})
        except (ValueError, TypeError, AttributeError, RecursionError) as error:
            self.respond(400, {"error": str(error)})
        except (OSError, subprocess.TimeoutExpired) as error:
            message = error.stderr if self.path == "/api/open" and isinstance(error, subprocess.TimeoutExpired) and isinstance(error.stderr, str) and error.stderr else str(error)
            self.respond(503, {"error": message})


def config_dir():
    config = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")
    return config / "peon-code"


def pid_file(port):
    return config_dir() / ("web-" + str(port) + ".pid")


def bind_server(port):
    automatic = port is None
    if automatic:
        port = DEFAULT_PORT
    try:
        return ThreadingHTTPServer(("127.0.0.1", port), Handler)
    except OSError as error:
        original = error
    if original.errno == errno.EADDRINUSE:
        try:
            pid = int(pid_file(port).read_text())
            if not 1 < pid <= 2147483647 or pid == os.getpid():
                raise ValueError("Invalid server PID")
            process = subprocess.run(["ps", "-o", "args=", "-p", str(pid)],
                                     capture_output=True, text=True, timeout=1)
            if process.returncode or "web/server.py" not in process.stdout:
                raise ValueError("Port belongs to another process")
            os.kill(pid, signal.SIGTERM)
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline:
                try:
                    with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                        pass
                except OSError:
                    break
                time.sleep(0.05)
            return ThreadingHTTPServer(("127.0.0.1", port), Handler)
        except (OSError, ValueError, OverflowError, UnicodeError, subprocess.TimeoutExpired):
            pass
        if automatic:
            server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            print(f"port {port} is busy, using {server.server_port}", file=sys.stderr)
            return server
    raise original


def watch_parent(server, stopped):
    while not stopped.wait(5):
        if os.getppid() == 1:
            server.shutdown()
            return


def stop_server(signum, frame):
    raise SystemExit(0)


def main():
    args = arguments()
    if args.ssh:
        try:
            raise SystemExit(remote_ui(args))
        except (OSError, RuntimeError) as error:
            raise SystemExit(str(error)) from error
        except KeyboardInterrupt:
            return
    if not shutil.which("tmux"):
        raise SystemExit("peon-code-web requires tmux on the agent host")
    try:
        server = bind_server(args.port)
    except OSError as error:
        raise SystemExit("Cannot listen on loopback port " + str(args.port if args.port is not None else DEFAULT_PORT) + ": " + str(error) + ". Use --port <free-port>.") from error
    stopped = threading.Event()
    path = pid_file(server.server_port)
    pid = str(os.getpid())
    previous_handler = signal.signal(signal.SIGTERM, stop_server)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(pid + "\n")
        if args.directory:
            args.session = open_project(args, ROOT)
        if args.session and not panes(args.session):
            raise SystemExit("no peon-code agent panes in session " + args.session)
        server.address = "127.0.0.1:" + str(server.server_port)
        server.origin = "http://" + server.address
        server.token = secrets.token_urlsafe(32)
        server.session = None if args.directory else args.session
        server.initial = args.session
        server.send_lock = threading.Lock()
        url = server.origin + "/#" + server.token
        if args.stdio:
            print(json.dumps({"url": url}), flush=True)
            # Closing the local SSH client closes stdin and stops its remote server.
            threading.Thread(target=lambda: (sys.stdin.read(), server.shutdown()), daemon=True).start()
            threading.Thread(target=watch_parent, args=(server, stopped), daemon=True).start()
        else:
            print("peon-code-web: " + url + "\nKeep this command running. Press Ctrl-C to stop.", flush=True)
        if not args.no_open:
            threading.Thread(target=open_browser, args=(url,), daemon=True).start()
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        raise SystemExit(str(error)) from error
    finally:
        stopped.set()
        server.server_close()
        signal.signal(signal.SIGTERM, previous_handler)
        try:
            if path.read_text().strip() == pid:
                path.unlink()
        except OSError:
            pass


if __name__ == "__main__":
    main()
