"""Run with: conda run -n peon-chat python -m unittest discover -s tests -p 'test_web*.py'"""
import contextlib
import importlib.util
import io
import json
import os
import pty
import signal
import subprocess
import sys
import threading
import tempfile
import time
import unittest
from types import SimpleNamespace
from http.client import HTTPConnection
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "web"))
import bridge
import launch

spec = importlib.util.spec_from_file_location("peon_web", ROOT / "web/server.py")
web = importlib.util.module_from_spec(spec)
spec.loader.exec_module(web)


class WebTests(unittest.TestCase):
    def setUp(self):
        self.server = web.ThreadingHTTPServer(("127.0.0.1", 0), web.Handler)
        self.server.address = "127.0.0.1:" + str(self.server.server_port)
        self.server.origin = "http://" + self.server.address
        self.server.token = "test-token"
        self.server.session = "team"
        self.server.send_lock = threading.Lock()
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.panes = patch.object(web, "panes", return_value=[dict(id="%2", identity="server:session:pane", name="worker", session="team")])
        self.panes.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.panes.stop()

    def request(self, method, path, data=None, headers=None):
        connection = HTTPConnection("127.0.0.1", self.server.server_port, timeout=5)
        values = {"X-Peon-Token": "test-token", "Content-Type": "application/json"}
        values.update(headers or {})
        body = json.dumps(data) if data is not None else None
        connection.request(method, path, body=body, headers=values)
        response = connection.getresponse()
        status, body = response.status, response.read()
        connection.close()
        return status, body

    def test_access_and_output(self):
        self.assertEqual(self.request("GET", "/")[0], 200)
        self.assertEqual(self.request("GET", "/api/panes", headers={"X-Peon-Token": ""})[0], 403)
        self.assertEqual(self.request("GET", "/api/panes", headers={"X-Peon-Token": "é"})[0], 403)
        self.assertEqual(self.request("GET", "/", headers={"Host": "evil.test"})[0], 403)
        self.assertEqual(self.request("GET", "/api/panes", headers={"Origin": "https://evil.test"})[0], 403)
        with patch.object(web, "snapshot", side_effect=lambda pane: dict(pane, output="It's 日本語 <script>\nsecond line")):
            status, body = self.request("GET", "/api/panes")
        self.assertEqual(status, 200)
        self.assertIn("日本語", json.loads(body)["panes"][0]["output"])

    def test_scrollback_depth_validation_and_authentication(self):
        path = "/api/panes?pane=%252&lines="
        self.assertEqual(self.request("GET", path + "2000", headers={"X-Peon-Token": ""})[0], 403)
        with patch.object(web, "snapshot") as snapshot:
            for value in ("999", "200001", "-1", "text", "1000.5", ""):
                with self.subTest(lines=value):
                    self.assertEqual(self.request("GET", path + value)[0], 400)
            snapshot.assert_not_called()

    def test_scrollback_depth_only_applies_to_named_pane(self):
        panes = [dict(id="%2"), dict(id="%3")]
        with patch.object(web, "panes", return_value=panes):
            for lines in (1000, 2000, 200000):
                with self.subTest(lines=lines), patch.object(web, "snapshot", side_effect=lambda pane, lines=1000: dict(pane, output="terminal", history=2500)) as snapshot:
                    status, body = self.request("GET", "/api/panes?pane=%252&lines=" + str(lines))
                    self.assertEqual(status, 200)
                    self.assertEqual(snapshot.call_args_list[0].args, (panes[0], lines))
                    self.assertEqual(snapshot.call_args_list[1].args, (panes[1],))
                    self.assertEqual([pane["history"] for pane in json.loads(body)["panes"]], [2500, 2500])

    def test_same_pane_send_and_failures(self):
        text = "It's `quoted` $(touch /tmp/never-run)\n日本語"
        with patch.object(web, "run_delivery", return_value=subprocess.CompletedProcess([], 0, "sent", "")) as run:
            status, _ = self.request("POST", "/api/explain", dict(pane="%2", identity="server:session:pane", text=text))
            self.assertEqual(status, 200)
            self.assertEqual(run.call_args.args[0], [str(ROOT / "peon-code.sh"), "explain", "%2"])
            self.assertEqual(run.call_args.args[1:], (text, "server:session:pane"))
            self.assertEqual(self.request("POST", "/api/send", dict(pane="%999", text=text))[0], 400)
            self.assertEqual(self.request("POST", "/api/send", dict(pane="%2", identity="server:session:pane", text=" "))[0], 400)
            self.assertEqual(self.request("POST", "/api/send", dict(pane="%2", identity="server:session:pane", text=text), {"Origin": "https://evil.test"})[0], 403)
            self.assertEqual(self.request("POST", "/api/send", dict(pane="%2", identity="old:server:pane", text=text))[0], 400)
            self.assertEqual(run.call_count, 1)
        with patch.object(web, "run_delivery", return_value=subprocess.CompletedProcess([], 1, "target box busy", "")):
            status, body = self.request("POST", "/api/send", dict(pane="%2", identity="server:session:pane", text=text))
            self.assertEqual(status, 409)
            self.assertIn("target box busy", json.loads(body)["error"])
        with patch.object(web, "run_delivery", side_effect=subprocess.TimeoutExpired("delivery", 20)):
            self.assertEqual(self.request("POST", "/api/send", dict(pane="%2", identity="server:session:pane", text=text))[0], 503)

    def test_timeout_stops_guard_and_child_before_failure(self):
        result = web.run_delivery(["bash", "-c", 'cat; printf "%s" "$PEON_EXPECTED_IDENTITY" >&2; exit 7'], "日本語", "test-identity")
        self.assertEqual((result.returncode, result.stdout, result.stderr), (7, "日本語", "test-identity"))
        with tempfile.TemporaryDirectory() as folder:
            marker = Path(folder) / "submitted"
            identity = folder + ":%8"
            key = subprocess.run(["cksum"], input=identity, text=True, capture_output=True, check=True).stdout.split()[0]
            lock = Path("/tmp") / ("peon-code-delivery-" + str(os.getuid())) / key
            script = 'source lib/delivery.sh; marker=$1; socket=$2; tmux() { printf "%s" "$socket:%8"; }; callback() { touch "$marker.started"; sleep 0.5; touch "$marker"; }; with_pane_delivery %8 callback'
            args = ["bash", "-c", script, "bash", str(marker), folder]
            try:
                deliver = web.run_delivery
                with patch.object(web, "run_delivery", side_effect=lambda *_: deliver(args, "", identity, timeout=0.2)):
                    status, _ = self.request("POST", "/api/send", dict(pane="%2", identity="server:session:pane", text="message"))
                self.assertEqual(status, 503)
                self.assertTrue(Path(str(marker) + ".started").exists())
                time.sleep(0.6)
                self.assertFalse(marker.exists())
                self.assertTrue(lock.is_dir())
                self.assertEqual(web.run_delivery(args, "", identity).returncode, 75)
            finally:
                if lock.exists():
                    (lock / "owner").unlink(missing_ok=True)
                    lock.rmdir()

    def test_closed_or_replaced_snapshot_is_omitted(self):
        for result in (None, subprocess.CalledProcessError(1, 'tmux')):
            with self.subTest(result=result), patch.object(web, 'snapshot', side_effect=result if isinstance(result, Exception) else None, return_value=None):
                status, body = self.request('GET', '/api/panes')
                self.assertEqual(status, 200)
                self.assertEqual(json.loads(body)['panes'], [])

    def test_deep_json_returns_bad_request(self):
        connection = HTTPConnection("127.0.0.1", self.server.server_port, timeout=5)
        try:
            body = "[" * 20000 + "0" + "]" * 20000
            connection.request("POST", "/api/send", body=body, headers={"X-Peon-Token": "test-token", "Content-Type": "application/json"})
            response = connection.getresponse()
            self.assertEqual(response.status, 400)
            self.assertIn("error", json.loads(response.read()))
        finally:
            connection.close()

    def test_clone_fallback_keeps_terminal_credentials_and_caps_headless(self):
        for interactive in (True, False):
            with self.subTest(interactive=interactive), tempfile.TemporaryDirectory() as directory:
                fake = Path(directory) / "git"
                log = Path(directory) / "git.log"
                fake.write_text("#!" + sys.executable + "\n" + '''import os, sys, time
command = sys.argv[3]
if command == "rev-parse":
    print("refs/remotes/origin/main" if "--symbolic-full-name" in sys.argv else "1" * 40)
elif command == "symbolic-ref":
    print("main")
elif command == "config":
    print("origin" if sys.argv[5].endswith(".remote") else "refs/heads/main")
elif command == "ls-remote":
    source = sys.argv[5]
    with open(os.environ["TEST_LOG"], "a") as log:
        log.write(f"{source}|{os.environ['GIT_TERMINAL_PROMPT']}|{int(os.isatty(0))}\\n")
    if source != "origin":
        sys.exit(1)
    time.sleep(2)
    print("2" * 40 + "\\trefs/heads/main")
elif command in ("merge-base", "cat-file"):
    sys.exit(1)
elif command == "pull":
    with open(os.environ["TEST_LOG"], "a") as log:
        log.write(f"pull|{sys.argv[6]}|{os.environ['GIT_TERMINAL_PROMPT']}\\n")
''')
                fake.chmod(0o755)
                environment = dict(os.environ, PATH=directory + os.pathsep + os.environ.get("PATH", ""),
                                   TEST_LOG=str(log), PEON_FETCH_TIMEOUT="1", PEON_UPDATE_PAUSE="0",
                                   PEON_UPDATE_URL="https://public.invalid/repo.git", GIT_TERMINAL_PROMPT="caller")
                master, slave = pty.openpty()
                process = None
                try:
                    process = subprocess.Popen(["bash", "-c", 'SCRIPT_DIR=$1; source "$1/lib/config.sh"; offer_update || true', "bash", str(ROOT)],
                                               stdin=slave if interactive else subprocess.PIPE, stdout=subprocess.PIPE,
                                               stderr=subprocess.PIPE, text=True, env=environment, start_new_session=True)
                    os.close(slave)
                    slave = None
                    if interactive:
                        os.write(master, b"y\n")
                    stdout, stderr = process.communicate(None if interactive else "y\n", timeout=6)
                    self.assertEqual(process.returncode, 0)
                    self.assertIn("trying origin", stderr)
                    self.assertEqual(stdout, "")
                    rows = log.read_text().splitlines()
                    self.assertEqual(rows[0], "https://public.invalid/repo.git|0|" + str(int(interactive)))
                    if interactive:
                        self.assertEqual(rows[1:], ["origin|caller|1", "pull|origin|caller"])
                        self.assertIn("updated; starting", stderr)
                    else:
                        self.assertEqual(rows[1:], ["origin|0|0"])
                        self.assertIn("starting current version", stderr)
                        self.assertNotIn("pull now", stderr)
                finally:
                    if process is not None and process.poll() is None:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.communicate()
                    if slave is not None:
                        os.close(slave)
                    os.close(master)

    def test_automatic_browser_open_both_platforms(self):
        for platform, opener in [("darwin", "open"), ("linux", "xdg-open")]:
            with self.subTest(platform=platform), patch.object(sys, "platform", platform), patch.object(launch.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)) as run:
                launch.open_browser("http://127.0.0.1:8765/#test")
                self.assertEqual(run.call_args.args[0][0], opener)
                self.assertTrue(run.call_args.args[0][1].startswith("http://127.0.0.1:"))

    def test_occupied_port_does_not_start_agents(self):
        args = SimpleNamespace(ssh=None, directory='/project', port=8765)
        with patch.object(web, 'arguments', return_value=args), patch.object(web, 'ThreadingHTTPServer', side_effect=OSError('address in use')), patch.object(web, 'open_project') as start, self.assertRaisesRegex(SystemExit, 'Use --port'):
            web.main()
        start.assert_not_called()

    def test_failed_creation_closes_reserved_server(self):
        args = SimpleNamespace(ssh=None, directory='/project', port=0)
        with patch.object(web, 'arguments', return_value=args), patch.object(web, 'ThreadingHTTPServer') as server, patch.object(web, 'open_project', side_effect=RuntimeError('bad project')), self.assertRaisesRegex(SystemExit, 'bad project'):
            web.main()
        server.return_value.server_close.assert_called_once()


if __name__ == "__main__":
    unittest.main()
