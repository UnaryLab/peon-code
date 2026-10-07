"""Local launch and one-command SSH forwarding without external packages."""
import argparse
import json
import re
import shlex
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlsplit

DEFAULT_PORT = 8765
REMOTE_CONFIG_DIR = Path(".config/peon-code/uploads")


def arguments():
    parser = argparse.ArgumentParser(prog="peon-code-web", description="Open your peon-code teams in a browser.", allow_abbrev=False)
    parser.add_argument("session", nargs="?", help="session name (defaults to the folder name with --dir)")
    parser.add_argument("--no-open", action="store_true", help="print the URL without opening a browser")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help="loopback port (default: %(default)s; 0 picks a free local port)")
    parser.add_argument("--ssh", metavar="HOST", help="start the remote UI, forward it, and open your local browser")
    parser.add_argument("--dir", dest="directory", metavar="PATH", help="create or open this project (resolved on the agent host)")
    parser.add_argument("--config", type=Path, metavar="PATH", help="use this local team config with --dir; upload it with --ssh")
    parser.add_argument("--stdio", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.directory == "":
        parser.error("--dir requires a non-empty project path")
    if args.config is not None:
        if not args.directory:
            parser.error("--config requires --dir")
        args.config = args.config.expanduser().resolve()
        if not args.config.is_file():
            parser.error("Config file does not exist: " + str(args.config))
    if not 0 <= args.port <= 65535 or (args.ssh and args.port == 0):
        parser.error("use a port from 1 to 65535 with --ssh; 0 is local-only")
    if args.ssh and (args.ssh.startswith("-") or not re.fullmatch(r"[A-Za-z0-9_.@:\[\]-]+", args.ssh)):
        parser.error("--ssh requires an SSH host alias or user@host")
    return args


def open_browser(url):
    opener = "open" if sys.platform == "darwin" else "xdg-open"
    try:
        result = subprocess.run([opener, url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
        if result.returncode == 0:
            return
    except (OSError, subprocess.TimeoutExpired):
        pass
    print("Could not open a browser; open the URL above on this computer.", flush=True)


def remote_config_path(args):
    name = args.session or Path(args.directory.rstrip("/")).name
    name = re.sub(r"[^A-Za-z0-9_.-]", "_", name) or "team"
    return REMOTE_CONFIG_DIR / (name + ".conf")


def ssh_command(args):
    remote_args = ["--stdio", "--no-open", "--port", str(args.port)]
    if args.directory:
        remote_args.extend(["--dir", args.directory])
    if getattr(args, "config", None):
        remote_args.extend(["--config", "~/" + str(remote_config_path(args))])
    if args.session:
        remote_args.extend(["--", args.session])
    remote = 'if command -v peon-code-web >/dev/null 2>&1; then exec peon-code-web ' + shlex.join(remote_args) + '; else exec "$HOME/.local/bin/peon-code-web" ' + shlex.join(remote_args) + '; fi'
    return ["ssh", "-T", "-o", "ExitOnForwardFailure=yes", "-L", f"127.0.0.1:{args.port}:127.0.0.1:{args.port}", "--", args.ssh, remote]


def remote_ui(args):
    config = getattr(args, "config", None)
    if config:
        path = remote_config_path(args)
        command = f'umask 077; mkdir -p "$HOME/{path.parent}" && cat > "$HOME/{path}" && chmod 600 "$HOME/{path}"'
        try:
            copied = subprocess.run(["ssh", "-T", "--", args.ssh, command], input=Path(config).read_bytes(), capture_output=True, timeout=30)
        except subprocess.TimeoutExpired as error:
            raise RuntimeError("Config copy to SSH host timed out") from error
        if copied.returncode:
            raise RuntimeError(copied.stderr.decode(errors="replace").strip() or "Config copy to SSH host failed")
    process = subprocess.Popen(ssh_command(args), stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    try:
        # Remote startup may include shell greetings; only trust a validated loopback rendezvous.
        for line in process.stdout:
            try:
                event = json.loads(line)
                if isinstance(event, dict) and type(event.get("update")) is int and 0 < event["update"] <= 1000000 and isinstance(event.get("host"), str) and re.fullmatch(r"[A-Za-z0-9._-]{1,255}", event["host"]):
                    reply = "n"
                    if sys.stdin.isatty():
                        try:
                            reply = input(f"Remote peon-code on {event['host']}: update available upstream; pull now? [y/N] ")
                        except EOFError:
                            pass
                    process.stdin.write(("y" if reply.lower() in ("y", "yes") else "n") + "\n")
                    process.stdin.flush()
                    continue
                url = event["url"]
                if not isinstance(url, str):
                    continue
                parsed = urlsplit(url)
                if parsed.scheme != "http" or parsed.netloc != f"127.0.0.1:{args.port}" or parsed.path != "/" or parsed.query or not re.fullmatch(r"[A-Za-z0-9_-]{43}", parsed.fragment):
                    continue
            except (ValueError, TypeError, KeyError):
                continue
            print("peon-code-web: " + url + "\nKeep this command running. Press Ctrl-C to stop the SSH connection.", flush=True)
            if not args.no_open:
                open_browser(url)
            return process.wait()
        raise RuntimeError("Remote UI did not start. Install peon-code-web on the SSH host and check the port is free.")
    finally:
        if process.stdin:
            try:
                process.stdin.close()
            except OSError:
                pass  # A disconnected peer must not prevent SSH cleanup.
        if process.poll() is None:
            process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        process.stdout.close()


def verify_project(session, project):
    marked = subprocess.run(["tmux", "show-options", "-qv", "-t", session, "@peon_code"], capture_output=True, text=True, timeout=5)
    if marked.returncode or marked.stdout.strip() != "1":
        raise RuntimeError("Session " + session + " is not a peon-code team; choose another SESSION name")
    stored = subprocess.run(["tmux", "display-message", "-p", "-t", session, "#{?#{@peon_project_dir},#{@peon_project_dir},#{session_path}}"], capture_output=True, text=True, timeout=5)
    directory = stored.stdout[:-1] if stored.stdout.endswith("\n") else stored.stdout
    if stored.returncode or not directory or Path(directory).expanduser().resolve() != project:
        raise RuntimeError("Session " + session + " belongs to a different project: " + (directory or "unknown folder") + "; choose another SESSION name")


def open_project(args, root):
    project = Path(args.directory).expanduser().resolve()
    if not project.is_dir():
        raise RuntimeError("Project folder does not exist: " + str(project))
    name = args.session or project.name
    if not name or name.startswith("-") or any(ord(char) < 32 or ord(char) == 127 for char in name):
        raise RuntimeError("Choose a valid SESSION name; the project folder must have a basename")
    session = name.replace(".", "_").replace(":", "_")
    exists = subprocess.run(["tmux", "has-session", "-t", "=" + session], capture_output=True, timeout=5)
    config = getattr(args, "config", None)
    if exists.returncode == 0:
        verify_project(session, project)
        if config:
            print(f"session {session} already runs; --config applies only to a new team", file=sys.stderr)
        return session
    if session in {"resume", "dismiss", "detach", "msg", "send", "explain", "rebrief", "compact", "clear", "watch", "list", "uninstall"}:
        raise RuntimeError("Session name is a peon-code command: " + session + ". Choose another SESSION name.")
    print("Starting team " + session + " in " + str(project) + "…", file=sys.stderr, flush=True)
    command = [str(root / "peon-code.sh")]
    if config:
        command.extend(["-c", str(Path(config).expanduser().resolve())])
    command.append(session)
    launched = subprocess.run(command, cwd=str(project), stdin=subprocess.DEVNULL, capture_output=True, text=True)
    if launched.returncode:
        raise RuntimeError((launched.stderr + launched.stdout).strip() or "Agent team could not start")
    verify_project(session, project)
    return session
