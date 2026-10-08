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
from bridge import panes, snapshot
from launch import arguments, open_browser, remote_ui, open_project
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

ROOT = Path(__file__).resolve().parent.parent
BUTTONS_DIR = ROOT / "buttons"
ASSETS = {"/": ("index.html", "text/html"), "/app.js": ("app.js", "text/javascript"),
          "/style.css": ("style.css", "text/css"),
          "/ansi.js": ("ansi.js", "text/javascript"),
          "/navigation.js": ("navigation.js", "text/javascript"),
          "/LICENSE": ("../LICENSE", "text/plain")}


def validate_button(data):
    name, description, prompt = data.get("name"), data.get("description"), data.get("prompt")
    name = name.strip(" ") if isinstance(name, str) else name
    if not isinstance(name, str) or not name or len(name) > 80 or not re.fullmatch(r"[A-Za-z0-9 _-]+", name):
        raise ValueError("Name must use 1 to 80 letters, digits, spaces, hyphens, or underscores")
    if not isinstance(description, str) or len(description) > 500 or "\n" in description or "\r" in description:
        raise ValueError("Description must be a single line of at most 500 characters")
    if not isinstance(prompt, str) or not prompt.strip() or len(prompt) > 200000:
        raise ValueError("Prompt must contain text and be at most 200000 characters")
    description.encode("utf-8")
    prompt.encode("utf-8")
    return dict(name=name, description=description, prompt=prompt)


def read_buttons():
    result = []
    paths = list(BUTTONS_DIR.glob("*.md")) + list((config_dir() / "buttons").glob("*.md"))
    for path in paths:
        try:
            match = re.fullmatch(r"---\r?\ndescription: ([^\r\n]*)\r?\n---\r?\n([\s\S]*)", path.read_bytes().decode("utf-8"))
            if match:
                result.append(validate_button(dict(name=path.stem, description=match[1], prompt=match[2])))
        except (ValueError, OSError):
            continue
    return sorted(result, key=lambda button: button["name"])


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
            try:
                result = []
                for pane in panes(self.server.session):
                    try:
                        captured = snapshot(pane, lines) if pane["id"] == target else snapshot(pane)
                        if captured is not None:
                            result.append(captured)
                    except subprocess.CalledProcessError:
                        continue
                self.respond(200, {"panes": result, "initial": self.server.initial})
            except (OSError, subprocess.TimeoutExpired) as error:
                self.respond(503, {"error": str(error)})
        else:
            self.respond(404, {"error": "Not found"})

    def do_POST(self):
        if not self.allowed(True):
            return
        if self.path not in ("/api/explain", "/api/send", "/api/dismiss", "/api/keys", "/api/buttons"):
            self.respond(404, {"error": "Not found"})
            return
        try:
            size = int(self.headers.get("Content-Length", "0"))
            if not 0 < size <= 262144 or self.headers.get_content_type() != "application/json":
                raise ValueError("Expected JSON, at most 256 KiB")
            data = json.loads(self.rfile.read(size))
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
                        file.write("---\ndescription: " + button["description"] + "\n---\n" + button["prompt"])
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
            self.respond(503, {"error": str(error)})


def config_dir():
    config = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")
    return config / "peon-code"


def pid_file(port):
    return config_dir() / ("web-" + str(port) + ".pid")


def bind_server(port):
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
        raise SystemExit("Cannot listen on loopback port " + str(args.port) + ": " + str(error) + ". Use --port <free-port>.") from error
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
