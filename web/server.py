"""Loopback-only browser bridge to existing peon-code tmux panes."""
import json
import errno
import io
import mimetypes
import os
import re
import secrets
import signal
import subprocess
import sys
import shutil
import socket
import stat
import time
import tempfile
import zipfile
from bridge import panes, snapshot, tmux
from launch import arguments, open_browser, remote_ui, open_project, MissingProjectFolder, DEFAULT_PORT, REMOTE_CONFIG_DIR
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace
from urllib.parse import parse_qs, quote, urlsplit

ROOT = Path(__file__).resolve().parent.parent
try:
    VERSION = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
except OSError:
    VERSION = ""
BUTTONS_DIR = ROOT / "buttons"
MAX_FILE_BYTES = 256 * 1024 * 1024
ASSETS = {"/": ("index.html", "text/html"), "/app.js": ("app.js", "text/javascript"),
          "/style.css": ("style.css", "text/css"),
          "/ansi.js": ("ansi.js", "text/javascript"),
          "/navigation.js": ("navigation.js", "text/javascript"),
          "/LICENSE": ("../LICENSE", "text/plain")}


def available_clis():
    result = []
    for path in (ROOT / "lib" / "cli").glob("*.sh"):
        if not path.is_file() or not re.fullmatch(r"[A-Za-z0-9._-]+", path.stem):
            continue
        name = re.escape(path.stem) + "_swap_args"
        definition = r"(?m)^[ \t]*(?:function[ \t]+" + name + r"(?:[ \t]*\([ \t]*\))?|" + name + r"[ \t]*\([ \t]*\))[ \t]*\s*\{"
        try:
            if re.search(definition, path.read_text(encoding="utf-8")):
                result.append(path.stem)
        except (OSError, UnicodeError):
            continue
    return sorted(result)


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
    if len(args) > 1 and args[1] == "swap":
        environment["TMUX_PANE"] = ""
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

    def respond(self, status, data, content_type="application/json", filename=None):
        body = json.dumps(data).encode() if content_type == "application/json" and filename is None else data
        self.send_response(status)
        self.send_header("Content-Type", content_type + ("; charset=utf-8" if filename is None else ""))
        if filename is not None:
            self.send_header("Content-Disposition", "attachment; filename*=UTF-8''" + quote(filename, safe=""))
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", "default-src 'self'; img-src 'self' blob:; frame-src blob:; frame-ancestors 'none'; base-uri 'none'")
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

    def project_path(self, session, relative, allow_root=False):
        if (not relative and not allow_root) or relative.startswith("/") or (relative and any(part in ("", ".", "..") for part in relative.rstrip("/").split("/"))) or any(ord(char) < 32 or ord(char) == 127 for char in relative) or len(relative.encode("utf-8")) > 1024:
            raise ValueError("Path must be relative, at most 1024 UTF-8 bytes, without empty, dot, or parent components or control characters")
        relative = relative.rstrip("/")
        pane = next((pane for pane in panes(self.server.session) if pane["session"] == session), None)
        if pane is None or not pane.get("projectDir"):
            raise ValueError("Session changed or closed; refresh before browsing files")
        project = Path(pane["projectDir"]).resolve()
        target = (project / relative).resolve()
        if not target.is_relative_to(project):
            raise ValueError("Path must stay inside the session project directory")
        return relative, target

    def do_GET(self):
        parsed = urlsplit(self.path)
        if not self.allowed(parsed.path in ("/api/panes", "/api/buttons", "/api/clis", "/api/files", "/api/file")):
            return
        if self.path in ASSETS:
            filename, mime = ASSETS[self.path]
            self.respond(200, (ROOT / "web" / filename).read_bytes(), mime)
        elif parsed.path == "/api/clis":
            self.respond(200, available_clis())
        elif parsed.path == "/api/buttons":
            try:
                self.respond(200, read_buttons())
            except OSError as error:
                self.respond(503, {"error": str(error)})
        elif parsed.path in ("/api/files", "/api/file"):
            query = parse_qs(parsed.query, keep_blank_values=True)
            listing = parsed.path == "/api/files"
            try:
                relative, target = self.project_path(query.get("session", [""])[0], query.get("dir" if listing else "path", [""])[0], allow_root=True)
                if listing:
                    entries = []
                    with os.scandir(target) as folder:
                        # List at most 2000 entries; add pagination for larger folders.
                        for entry in folder:
                            if len(entries) >= 2000:
                                break
                            metadata = entry.stat(follow_symlinks=False)
                            kind = "dir" if stat.S_ISDIR(metadata.st_mode) else "file" if stat.S_ISREG(metadata.st_mode) else "other"
                            entries.append(dict(name=entry.name, type=kind, size=metadata.st_size if kind == "file" else None, modified=int(metadata.st_mtime)))
                    entries.sort(key=lambda entry: (entry["type"] != "dir", entry["name"].casefold()))
                    self.respond(200, {"dir": relative, "entries": entries})
                else:
                    metadata = target.stat()
                    if stat.S_ISDIR(metadata.st_mode):
                        files, total = [], 0
                        def walk_error(error):
                            raise error
                        for directory, _, names in os.walk(target, followlinks=False, onerror=walk_error):
                            for name in names:
                                file = Path(directory) / name
                                metadata = file.lstat()
                                if not stat.S_ISREG(metadata.st_mode):
                                    continue
                                total += metadata.st_size
                                if total > MAX_FILE_BYTES:
                                    self.respond(413, {"error": "Folder contents exceed 256 MiB"})
                                    return
                                files.append(file)
                        # Build the archive in memory; stream to a temp file if larger archives matter.
                        content = io.BytesIO()
                        with zipfile.ZipFile(content, "w", compression=zipfile.ZIP_DEFLATED, strict_timestamps=False) as archive:
                            for file in files:
                                archive.write(file, file.relative_to(target).as_posix())
                        self.respond(200, content.getvalue(), "application/zip", filename=(Path(relative).name if relative else target.name) + ".zip")
                        return
                    if not stat.S_ISREG(metadata.st_mode):
                        self.respond(404, {"error": "Not a regular file"})
                        return
                    if metadata.st_size > MAX_FILE_BYTES:
                        self.respond(413, {"error": "File exceeds 256 MiB"})
                        return
                    with target.open("rb") as file:
                        content = file.read(MAX_FILE_BYTES + 1)
                    if len(content) > MAX_FILE_BYTES:
                        self.respond(413, {"error": "File exceeds 256 MiB"})
                        return
                    self.respond(200, content, mimetypes.guess_type(relative)[0] or "application/octet-stream", filename=Path(relative).name)
            except (ValueError, RuntimeError) as error:
                self.respond(400, {"error": str(error)})
            except (FileNotFoundError, NotADirectoryError) as error:
                self.respond(404, {"error": str(error)})
            except OSError as error:
                self.respond(503, {"error": str(error)})
        elif parsed.path == "/api/panes":
            query = parse_qs(parsed.query, keep_blank_values=True)
            target = query.get("pane", [None])[0]
            resize_session = query.get("session", [None])[0]
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
                    # Detached panes need separate windows so their widths stay independent.
                    # Resize only the named session's viewed pane; restore joined panes on attach.
                    # With several browser tabs, the last poll for a pane sets its size.
                    for session in sorted({pane["session"] for pane in current}):
                        try:
                            window = session + ":agents"
                            if tmux("list-clients", "-t", "=" + session).strip():
                                session_panes = [row.split("\t") for row in tmux("list-panes", "-s", "-t", "=" + session, "-F", "#{pane_id}\t#{window_name}").splitlines()]
                                outside = {pane for pane, name in session_panes if name != "agents"}
                                if tmux("show-options", "-wv", "-t", window, "window-size").strip() == "manual" or outside:
                                    order = tmux("show-options", "-qv", "-t", session, "@peon_pane_order").split()
                                    if not order:
                                        order = sorted((pane for pane, _ in session_panes), key=lambda pane: int(pane[1:]))
                                    for pane in order:
                                        if pane in outside:
                                            tmux("join-pane", "-d", "-s", pane, "-t", window)
                                    order = [pane for pane in order if any(pane == existing for existing, _ in session_panes)]
                                    for index, pane in enumerate(order):
                                        joined = tmux("list-panes", "-t", window, "-F", "#{pane_id}").split()
                                        if joined[index] != pane:
                                            tmux("swap-pane", "-d", "-s", pane, "-t", joined[index])
                                    tmux("set", "-w", "-t", window, "-u", "window-size")
                                    tmux("set-option", "-w", "-t", window, "main-pane-width", "60%")
                                    tmux("select-layout", "-t", window, "main-vertical")
                                    tmux("set-option", "-u", "-t", session, "@peon_pane_order")
                                continue
                            if session != resize_session or not any(pane["id"] == target and pane["session"] == session for pane in current):
                                continue
                            if not tmux("show-options", "-qv", "-t", session, "@peon_pane_order").strip():
                                order = tmux("list-panes", "-t", window, "-F", "#{pane_id}").split()
                                tmux("set-option", "-t", session, "@peon_pane_order", " ".join(order))
                            for pane in tmux("list-panes", "-s", "-t", "=" + session, "-F", "#{pane_id}").split():
                                if int(tmux("display-message", "-p", "-t", pane, "#{window_panes}").strip()) > 1:
                                    tmux("break-pane", "-d", "-s", pane, "-t", "=" + session + ":", "-n", "p" + pane[1:])
                            window = tmux("display-message", "-p", "-t", target, "#{window_id}").strip()
                            width, height, pane_height = map(int, tmux("display-message", "-p", "-t", window, "#{window_width}\t#{window_height}\t#{pane_height}").split())
                            # A single broken pane has no border; agents retains its top border row.
                            desired_height = rows + height - pane_height
                            if (width, height) != (cols, desired_height):
                                tmux("resize-window", "-t", window, "-x", str(cols), "-y", str(desired_height))
                        except (OSError, subprocess.TimeoutExpired, subprocess.CalledProcessError):
                            errors = self.server.__dict__.setdefault("resize_errors", set())
                            if session not in errors:
                                errors.add(session)
                                print(f"Could not resize browser panes for {session!r}", file=sys.stderr)
                result = []
                for pane in current:
                    try:
                        captured = snapshot(pane, lines, rows) if pane["id"] == target else snapshot(pane)
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
        parsed = urlsplit(self.path)
        if parsed.path not in ("/api/explain", "/api/send", "/api/swap", "/api/dismiss", "/api/keys", "/api/buttons", "/api/open", "/api/upload"):
            self.respond(404, {"error": "Not found"})
            return
        try:
            size = int(self.headers.get("Content-Length", "0"))
            if parsed.path == "/api/upload":
                if not 0 <= size <= 64 * 1024 * 1024 or self.headers.get_content_type() != "application/octet-stream":
                    raise ValueError("Expected file bytes, at most 64 MiB")
                query = parse_qs(parsed.query, keep_blank_values=True)
                session, name = query.get("session", [""])[0], query.get("name", [""])[0]
                folder = query.get("dir", ["upload"])[0]
                if not name or name in (".", "..") or "/" in name or "\\" in name or any(ord(char) < 32 or ord(char) == 127 for char in name) or len(name.encode("utf-8")) > 255:
                    raise ValueError("Filename must be a basename of at most 255 UTF-8 bytes without control characters")
                if not folder or folder.startswith("/") or any(part in ("", ".", "..") for part in folder.rstrip("/").split("/")) or any(ord(char) < 32 or ord(char) == 127 for char in folder) or len(folder.encode("utf-8")) > 1024:
                    raise ValueError("Folder must be a relative path of at most 1024 UTF-8 bytes without empty, dot, or parent components or control characters")
                folder = folder.rstrip("/")
                target = next((pane for pane in panes(self.server.session) if pane["session"] == session), None)
                if target is None or not target.get("projectDir"):
                    raise ValueError("Session changed or closed; refresh before uploading")
                project = Path(target["projectDir"]).resolve()
                directory = project / folder
                if not directory.resolve().is_relative_to(project):
                    raise ValueError("Folder must stay inside the session project directory")
                content = self.rfile.read(size)
                if len(content) != size:
                    raise ValueError("Incomplete upload")
                try:
                    directory.mkdir(parents=True, exist_ok=True)
                except (FileExistsError, NotADirectoryError) as error:
                    raise ValueError("Folder is not a directory") from error
                try:
                    with (directory / name).open("xb") as file:
                        file.write(content)
                except FileExistsError:
                    self.respond(409, {"error": "A file with this name already exists"})
                    return
                self.respond(200, {"message": "Saved " + folder + "/" + name})
                return
            limit = 2 * 1024 * 1024 if parsed.path == "/api/open" else 262144
            if not 0 < size <= limit or self.headers.get_content_type() != "application/json":
                raise ValueError("Expected JSON, at most " + ("2 MiB" if parsed.path == "/api/open" else "256 KiB"))
            data = json.loads(self.rfile.read(size))
            if parsed.path == "/api/open":
                directory, session = data.get("directory"), data.get("session", "")
                create = data.get("create", False)
                if not isinstance(create, bool):
                    raise ValueError("Create must be true or false")
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
                    opened = open_project(SimpleNamespace(directory=directory, session=session, config=config), ROOT, timeout=300, create=create)
                except MissingProjectFolder as error:
                    self.respond(409, {"error": str(error), "create": True, "directory": error.directory})
                    return
                except RuntimeError as error:
                    raise ValueError(str(error)) from error
                finally:
                    if config is not None:
                        config.unlink(missing_ok=True)
                self.server.session = None
                self.respond(200, {"session": opened})
                return
            if parsed.path == "/api/buttons":
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
            if parsed.path == "/api/dismiss":
                session = data.get("session")
                if not isinstance(session, str) or not session or not any(p["session"] == session for p in panes(self.server.session)):
                    raise ValueError("Session changed or closed; refresh before closing")
                print("Closing team " + session + "…", file=sys.stderr, flush=True)
                result = subprocess.run([str(ROOT / "peon-code.sh"), "dismiss", session],
                                        stdin=subprocess.DEVNULL, capture_output=True, text=True,
                                        timeout=10, start_new_session=True)
                message = (result.stdout + result.stderr).strip() or ("Session closed" if result.returncode == 0 else "Could not close session")
                self.respond(200 if result.returncode == 0 else 409,
                             {"message" if result.returncode == 0 else "error": message})
                return
            pane, text, identity = data.get("pane"), data.get("text"), data.get("identity")
            append = data.get("append", False)
            if parsed.path == "/api/send" and not isinstance(append, bool):
                raise ValueError("append must be a boolean")
            if parsed.path == "/api/swap":
                cli, model, effort = (data.get(field) for field in ("cli", "model", "effort"))
                for field, value in (("CLI", cli), ("Model", model), ("Effort", effort)):
                    if not isinstance(value, str) or not re.fullmatch(r"(-|[A-Za-z0-9._=/][A-Za-z0-9._=/-]*)", value):
                        raise ValueError(field + " must be one token, or - to keep its value")
                if cli != "-" and cli not in available_clis():
                    raise ValueError("Unknown CLI")
                text = ""
            elif parsed.path == "/api/keys":
                key = data.get("key")
                if key not in ("Tab", "Up", "Down", "Enter", "Escape", "Backspace", "C-c"):
                    raise ValueError("Allowed keys: Tab, Up, Down, Enter, Escape, Backspace, C-c")
                text = ""
            elif not isinstance(text, str) or not text.strip():
                raise ValueError("Select or enter some text first")
            # ponytail: one send at a time; use per-pane locks if concurrent delivery matters.
            with self.server.send_lock:
                target = next((p for p in panes(self.server.session) if p["id"] == pane and p.get("identity") == identity), None)
                if not isinstance(identity, str) or target is None:
                    raise ValueError("Agent changed or closed; refresh before sending")
                action = "swap" if parsed.path == "/api/swap" else "key" if parsed.path == "/api/keys" else "explain" if parsed.path == "/api/explain" else "send"
                args = [str(ROOT / "peon-code.sh"), action]
                if action == "send" and append:
                    args.append("--append")
                if action == "key" and key == "Enter":
                    args.append("--submit")
                if action == "swap":
                    args.extend([target["name"], cli, model, effort, target["session"]])
                else:
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
            message = error.stderr if parsed.path == "/api/open" and isinstance(error, subprocess.TimeoutExpired) and isinstance(error.stderr, str) and error.stderr else str(error)
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
            try:
                args.session = open_project(args, ROOT)
            except MissingProjectFolder as error:
                reply = "n"
                if args.stdio:
                    print(json.dumps({"folder": error.directory}), flush=True)
                    reply = sys.stdin.readline()
                elif sys.stdin.isatty():
                    try:
                        reply = input(f"Folder {error.directory} does not exist. Create it? [y/N] ")
                    except EOFError:
                        pass
                if reply.strip().lower() not in ("y", "yes"):
                    raise
                args.directory = error.directory
                args.session = open_project(args, ROOT, create=True)
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
