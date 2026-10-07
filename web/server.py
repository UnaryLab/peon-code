"""Loopback-only browser bridge to existing peon-code tmux panes."""
import json
import os
import secrets
import signal
import subprocess
import sys
import shutil
from bridge import panes, snapshot
from launch import arguments, open_browser, remote_ui, open_project
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ASSETS = {"/": ("index.html", "text/html"), "/app.js": ("app.js", "text/javascript"),
          "/style.css": ("style.css", "text/css"),
          "/ansi.js": ("ansi.js", "text/javascript"),
          "/navigation.js": ("navigation.js", "text/javascript"),
          "/LICENSE": ("../LICENSE", "text/plain")}


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
        if not self.allowed(self.path == "/api/panes"):
            return
        if self.path in ASSETS:
            filename, mime = ASSETS[self.path]
            self.respond(200, (ROOT / "web" / filename).read_bytes(), mime)
        elif self.path == "/api/panes":
            try:
                result = []
                for pane in panes(self.server.session):
                    try:
                        captured = snapshot(pane)
                        if captured is not None:
                            result.append(captured)
                    except subprocess.CalledProcessError:
                        continue
                self.respond(200, {"panes": result})
            except (OSError, subprocess.TimeoutExpired) as error:
                self.respond(503, {"error": str(error)})
        else:
            self.respond(404, {"error": "Not found"})

    def do_POST(self):
        if not self.allowed(True):
            return
        if self.path not in ("/api/explain", "/api/send"):
            self.respond(404, {"error": "Not found"})
            return
        try:
            size = int(self.headers.get("Content-Length", "0"))
            if not 0 < size <= 262144 or self.headers.get_content_type() != "application/json":
                raise ValueError("Expected JSON, at most 256 KiB")
            data = json.loads(self.rfile.read(size))
            pane, text, identity = data.get("pane"), data.get("text"), data.get("identity")
            if not isinstance(text, str) or not text.strip():
                raise ValueError("Select or enter some text first")
            # ponytail: one send at a time; use per-pane locks if concurrent delivery matters.
            with self.server.send_lock:
                if not isinstance(identity, str) or not any(p["id"] == pane and p.get("identity") == identity for p in panes(self.server.session)):
                    raise ValueError("Agent changed or closed; refresh before sending")
                action = "explain" if self.path == "/api/explain" else "send"
                args = [str(ROOT / "peon-code.sh"), action, pane]
                if action == "send":
                    args.append("-")
                result = run_delivery(args, text, identity)
            message = (result.stdout + result.stderr).strip() or ("Sent" if result.returncode == 0 else "Could not send; check the agent pane")
            self.respond(200 if result.returncode == 0 else 409,
                         {"message" if result.returncode == 0 else "error": message})
        except (ValueError, TypeError, AttributeError, RecursionError) as error:
            self.respond(400, {"error": str(error)})
        except (OSError, subprocess.TimeoutExpired) as error:
            self.respond(503, {"error": str(error)})


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
        server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    except OSError as error:
        raise SystemExit("Cannot listen on loopback port " + str(args.port) + ": " + str(error) + ". Use --port <free-port>.") from error
    try:
        if args.directory:
            args.session = open_project(args, ROOT)
        if args.session and not panes(args.session):
            raise SystemExit("no peon-code agent panes in session " + args.session)
        server.address = "127.0.0.1:" + str(server.server_port)
        server.origin = "http://" + server.address
        server.token = secrets.token_urlsafe(32)
        server.session = args.session
        server.send_lock = threading.Lock()
        url = server.origin + "/#" + server.token
        if args.stdio:
            print(json.dumps({"url": url}), flush=True)
            # Closing the local SSH client closes stdin and stops its remote server.
            threading.Thread(target=lambda: (sys.stdin.read(), server.shutdown()), daemon=True).start()
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
        server.server_close()


if __name__ == "__main__":
    main()
