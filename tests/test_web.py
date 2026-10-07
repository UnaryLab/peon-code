"""Run with: conda run -n peon-chat python -m unittest discover -s tests -p 'test_web*.py'"""
import contextlib
import errno
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
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "web"))
import bridge
import launch

spec = importlib.util.spec_from_file_location("peon_web", ROOT / "web/server.py")
web = importlib.util.module_from_spec(spec)
spec.loader.exec_module(web)


class WebTests(unittest.TestCase):
    def setUp(self):
        self.config = tempfile.TemporaryDirectory()
        self.addCleanup(self.config.cleanup)
        self.environment = patch.dict(os.environ, XDG_CONFIG_HOME=self.config.name)
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.server = web.ThreadingHTTPServer(("127.0.0.1", 0), web.Handler)
        self.server.address = "127.0.0.1:" + str(self.server.server_port)
        self.server.origin = "http://" + self.server.address
        self.server.token = "test-token"
        self.server.session = "team"
        self.server.initial = "team"
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

    def test_send_append_boolean_and_delivery_arguments(self):
        data = dict(pane="%2", identity="server:session:pane", text="It's `quoted`\n日本語")
        with patch.object(web, "run_delivery", return_value=subprocess.CompletedProcess([], 0, "sent", "")) as run:
            for options, flags in (({}, []), ({"append": False}, []), ({"append": True}, ["--append"])):
                with self.subTest(options=options):
                    self.assertEqual(self.request("POST", "/api/send", dict(data, **options))[0], 200)
                    run.assert_called_with([str(ROOT / "peon-code.sh"), "send", *flags, "%2", "-"], data["text"], data["identity"])
            for value in ("true", "false", 1, 0, None, [], {}):
                with self.subTest(append=value):
                    status, body = self.request("POST", "/api/send", dict(data, append=value))
                    self.assertEqual((status, json.loads(body)), (400, {"error": "append must be a boolean"}))
            for headers in ({"X-Peon-Token": "bad-token"}, {"Host": "evil.test"}, {"Origin": "https://evil.test"}):
                self.assertEqual(self.request("POST", "/api/send", dict(data, append=True), headers)[0], 403)
            for options in ({"identity": "old:pane"}, {"pane": "%999"}, {"text": " "}, {"padding": "x" * 262144}):
                self.assertEqual(self.request("POST", "/api/send", dict(data, append=True, **options))[0], 400)
            self.assertEqual(run.call_count, 3)

    def test_keys_validate_identity_and_only_send_allowed_keys(self):
        keys = ("Tab", "Up", "Down", "Enter", "Escape")
        def deliver(args, text, identity):
            self.assertTrue(self.server.send_lock.locked())
            return subprocess.CompletedProcess(args, 0, "key sent", "")
        with patch.object(web, "run_delivery", side_effect=deliver) as run, patch.object(web, "snapshot") as snapshot:
            for key in keys:
                data = dict(pane="%2", identity="server:session:pane", key=key, text="Never send this text")
                status, body = self.request("POST", "/api/keys", data)
                self.assertEqual((status, json.loads(body)), (200, {"message": "key sent"}))
                flags = ["--submit"] if key == "Enter" else []
                run.assert_called_with([str(ROOT / "peon-code.sh"), "key", *flags, "%2", key], "", "server:session:pane")
            for key in (*"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ", "Esc", "tab", "10", "aa", "é", "C-c", "Tab Enter", "", None, 1, []):
                with self.subTest(key=key):
                    self.assertEqual(self.request("POST", "/api/keys", dict(pane="%2", identity="server:session:pane", key=key))[0], 400)
            data = dict(pane="%2", identity="server:session:pane", key="Enter")
            self.assertEqual(self.request("POST", "/api/keys", data, {"X-Peon-Token": "bad-token"})[0], 403)
            self.assertEqual(self.request("POST", "/api/keys", data, {"Origin": "https://evil.test"})[0], 403)
            self.assertEqual(self.request("POST", "/api/keys", dict(data, identity="old:pane"))[0], 400)
            self.assertEqual(self.request("POST", "/api/keys", dict(data, pane="%999"))[0], 400)
            self.assertEqual(self.request("POST", "/api/keys", dict(data, padding="x" * 262144))[0], 400)
            self.assertEqual(self.request("POST", "/api/keys", ["Tab"])[0], 400)
            self.assertEqual(run.call_count, len(keys))
            snapshot.assert_not_called()

    def test_keys_delivery_failure_and_timeout(self):
        data = dict(pane="%2", identity="server:session:pane", key="Enter")
        with patch.object(web, "run_delivery", return_value=subprocess.CompletedProcess([], 1, "", "no Enter sent: not on a menu")):
            status, body = self.request("POST", "/api/keys", data)
            self.assertEqual((status, json.loads(body)), (409, {"error": "no Enter sent: not on a menu"}))
        with patch.object(web, "run_delivery", side_effect=subprocess.TimeoutExpired("key", 20)):
            self.assertEqual(self.request("POST", "/api/keys", data)[0], 503)

    def test_dismiss_session_validation_and_authentication(self):
        session = "team 'quoted' $(literal)"
        with patch.object(web, "panes", return_value=[dict(session=session)]) as panes, \
                patch.object(web.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "closed", "")) as run:
            status, body = self.request("POST", "/api/dismiss", dict(session=session))
            self.assertEqual((status, json.loads(body)), (200, {"message": "closed"}))
            panes.assert_called_once_with("team")
            run.assert_called_once_with([str(ROOT / "peon-code.sh"), "dismiss", session],
                                        stdin=subprocess.DEVNULL, capture_output=True, text=True,
                                        timeout=10, start_new_session=True)
            for value in ("unknown", "", None, 2, []):
                with self.subTest(session=value):
                    self.assertEqual(self.request("POST", "/api/dismiss", dict(session=value))[0], 400)
            for data in ([], "session", 2, None):
                with self.subTest(data=data):
                    self.assertEqual(self.request("POST", "/api/dismiss", data)[0], 400)
            for headers in ({"X-Peon-Token": ""}, {"Host": "evil.test"}, {"Origin": "https://evil.test"}, {"Content-Type": "text/plain"}):
                with self.subTest(headers=headers):
                    self.assertEqual(self.request("POST", "/api/dismiss", dict(session=session), headers)[0],
                                     400 if "Content-Type" in headers else 403)
            self.assertEqual(self.request("POST", "/api/dismiss", dict(session=session, padding="x" * 262144))[0], 400)
            self.assertEqual(run.call_count, 1)

    def test_dismiss_failure_and_timeout(self):
        with patch.object(web.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "could not close\n", "busy")):
            status, body = self.request("POST", "/api/dismiss", dict(session="team"))
            self.assertEqual((status, json.loads(body)), (409, {"error": "could not close\nbusy"}))
        with patch.object(web.subprocess, "run", side_effect=subprocess.TimeoutExpired("dismiss", 10)):
            self.assertEqual(self.request("POST", "/api/dismiss", dict(session="team"))[0], 503)

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

    def test_directory_selects_initial_without_filtering_sessions(self):
        all_panes = [dict(id="%2", session="team"), dict(id="%3", session="zeta")]
        for directory, session, expected_filter, expected_initial in (
                ("/project", None, None, "zeta"),
                ("/project", "custom", None, "zeta"),
                (None, "team", "team", "team"),
                (None, None, None, None)):
            args = SimpleNamespace(ssh=None, directory=directory, session=session,
                                   port=0, stdio=False, no_open=True)
            with self.subTest(directory=directory, session=session), \
                    patch.object(web, "arguments", return_value=args), \
                    patch.object(web, "ThreadingHTTPServer", return_value=self.server), \
                    patch.object(web, "open_project", return_value="zeta") as start, \
                    patch.object(web.secrets, "token_urlsafe", return_value="test-token"), \
                    patch.object(self.server, "serve_forever"), \
                    patch.object(self.server, "server_close"), \
                    patch.object(web, "panes", side_effect=lambda selected: [pane for pane in all_panes if selected is None or pane["session"] == selected]) as panes, \
                    patch.object(web, "snapshot", side_effect=lambda pane: pane), \
                    contextlib.redirect_stdout(io.StringIO()):
                web.main()
                self.assertEqual(self.server.session, expected_filter)
                self.assertEqual(self.server.initial, expected_initial)
                if directory:
                    start.assert_called_once_with(args, ROOT)
                else:
                    start.assert_not_called()
                status, body = self.request("GET", "/api/panes")
                self.assertEqual(status, 200)
                panes.assert_called_with(expected_filter)
                self.assertEqual(json.loads(body), {
                    "panes": [pane for pane in all_panes if expected_filter is None or pane["session"] == expected_filter],
                    "initial": expected_initial})

    def test_failed_creation_closes_reserved_server(self):
        args = SimpleNamespace(ssh=None, directory='/project', port=0)
        with patch.object(web, 'arguments', return_value=args), patch.object(web, 'ThreadingHTTPServer') as server, patch.object(web, 'open_project', side_effect=RuntimeError('bad project')), self.assertRaisesRegex(SystemExit, 'bad project'):
            web.main()
        server.return_value.server_close.assert_called_once()


class ServerLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.config = tempfile.TemporaryDirectory()
        self.addCleanup(self.config.cleanup)
        environment = patch.dict(os.environ, XDG_CONFIG_HOME=self.config.name)
        environment.start()
        self.addCleanup(environment.stop)
        self.path = web.pid_file(8765)
        self.path.parent.mkdir(parents=True)
        self.error = OSError(errno.EADDRINUSE, "address in use")

    def test_orphan_watchdog_checks_every_five_seconds(self):
        server, stopped = Mock(), Mock()
        stopped.wait.side_effect = [False, False]
        with patch.object(web.os, "getppid", side_effect=[42, 1]) as parent:
            web.watch_parent(server, stopped)
        self.assertEqual(parent.call_count, 2)
        self.assertEqual([call.args for call in stopped.wait.call_args_list], [(5,), (5,)])
        server.shutdown.assert_called_once_with()
        stopped.wait.side_effect = None
        stopped.wait.return_value = True
        with patch.object(web.os, "getppid") as parent:
            web.watch_parent(server, stopped)
        parent.assert_not_called()

    def test_verified_server_is_terminated_then_bind_retries_once(self):
        self.path.write_text("12345\n")
        server = Mock()
        with patch.object(web, "ThreadingHTTPServer", side_effect=[self.error, server]) as bind, \
                patch.object(web.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "python /project/web/server.py --stdio\n", "")) as ps, \
                patch.object(web.os, "kill") as kill, \
                patch.object(web.socket, "create_connection", side_effect=ConnectionRefusedError) as connection:
            self.assertIs(web.bind_server(8765), server)
        ps.assert_called_once_with(["ps", "-o", "args=", "-p", "12345"], capture_output=True, text=True, timeout=1)
        kill.assert_called_once_with(12345, signal.SIGTERM)
        self.assertEqual(bind.call_count, 2)
        connection.assert_called_once_with(("127.0.0.1", 8765), timeout=0.1)

    def test_foreign_invalid_or_unreadable_pid_never_signaled(self):
        for contents in (None, "", "invalid", "0", "-2", "1", "999999999999999999999", str(os.getpid()), "12345"):
            with self.subTest(contents=contents):
                if contents is None:
                    self.path.unlink(missing_ok=True)
                else:
                    self.path.write_text(contents)
                with patch.object(web, "ThreadingHTTPServer", side_effect=self.error) as bind, \
                        patch.object(web.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "python another-server.py", "")) as ps, \
                        patch.object(web.os, "kill") as kill, self.assertRaises(OSError) as raised:
                    web.bind_server(8765)
                self.assertIs(raised.exception, self.error)
                kill.assert_not_called()
                self.assertEqual(bind.call_count, 1)
                self.assertEqual(ps.call_count, int(contents == "12345"))

    def test_lookup_signal_and_retry_failures_preserve_original_bind_error(self):
        self.path.write_text("12345")
        for lookup, kill_error in ((OSError("ps failed"), None),
                                   (subprocess.TimeoutExpired("ps", 1), None),
                                   (subprocess.CompletedProcess([], 1, "web/server.py", ""), None),
                                   (subprocess.CompletedProcess([], 0, "web/server.py", ""), PermissionError("kill denied")),
                                   (subprocess.CompletedProcess([], 0, "web/server.py", ""), None)):
            with self.subTest(lookup=lookup, kill_error=kill_error), \
                    patch.object(web, "ThreadingHTTPServer", side_effect=[self.error, OSError("retry failed")]) as bind, \
                    patch.object(web.subprocess, "run", side_effect=lookup if isinstance(lookup, Exception) else None, return_value=lookup), \
                    patch.object(web.os, "kill", side_effect=kill_error) as kill, \
                    patch.object(web.time, "monotonic", side_effect=[0, 0, 2]), \
                    patch.object(web.time, "sleep") as sleep, \
                    patch.object(web.socket, "create_connection"), self.assertRaises(OSError) as raised:
                web.bind_server(8765)
            self.assertIs(raised.exception, self.error)
            retry = not isinstance(lookup, Exception) and lookup.returncode == 0 and kill_error is None
            self.assertEqual(bind.call_count, 2 if retry else 1)
            self.assertEqual(kill.call_count, int(not isinstance(lookup, Exception) and lookup.returncode == 0))
            self.assertEqual(sleep.call_count, int(retry))

    def test_main_records_bound_port_and_cleans_up_on_exit(self):
        args = SimpleNamespace(ssh=None, directory=None, session=None, port=0, stdio=True, no_open=True)
        path = web.pid_file(9123)
        pid = str(os.getpid())
        for outcome in ("normal", "term", "new-owner"):
            server = Mock(server_port=9123)
            def serve():
                self.assertEqual(path.read_text(), pid + "\n")
                if outcome == "new-owner":
                    path.write_text("54321\n")
                elif outcome == "term":
                    web.stop_server(signal.SIGTERM, None)
            server.serve_forever.side_effect = serve
            previous_handler = signal.getsignal(signal.SIGTERM)
            with self.subTest(outcome=outcome), patch.object(web, "arguments", return_value=args), \
                    patch.object(web, "bind_server", return_value=server) as bind, \
                    patch.object(web.shutil, "which", return_value="tmux"), \
                    patch.object(web.threading, "Thread") as thread, contextlib.redirect_stdout(io.StringIO()):
                if outcome == "term":
                    with self.assertRaises(SystemExit) as raised:
                        web.main()
                    self.assertEqual(raised.exception.code, 0)
                else:
                    web.main()
            bind.assert_called_once_with(0)
            server.server_close.assert_called_once_with()
            self.assertEqual(signal.getsignal(signal.SIGTERM), previous_handler)
            self.assertEqual(thread.call_count, 2)
            watchdog = thread.call_args
            self.assertIs(watchdog.kwargs["target"], web.watch_parent)
            self.assertTrue(watchdog.kwargs["args"][1].is_set())
            self.assertEqual(path.exists(), outcome == "new-owner")
            if path.exists():
                self.assertEqual(path.read_text(), "54321\n")


if __name__ == "__main__":
    unittest.main()
