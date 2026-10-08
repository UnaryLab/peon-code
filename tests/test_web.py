"""Run with: conda run -n peon-chat python -m unittest discover -s tests -p 'test_web*.py'"""
import contextlib
import errno
import importlib.util
import io
from html import unescape
import json
import os
import pty
import signal
import subprocess
import shutil
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
        self.assertEqual(json.loads(body)["version"], (ROOT / "VERSION").read_text(encoding="utf-8").strip())

    def test_version_is_read_once_at_startup_and_missing_is_empty(self):
        for contents, expected in ((" 2.3.4\n", "2.3.4"), (FileNotFoundError(), "")):
            with self.subTest(expected=expected), patch.object(Path, "read_text", **({"side_effect": contents} if isinstance(contents, OSError) else {"return_value": contents})) as read:
                module = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(module)
                self.assertEqual(module.VERSION, expected)
                read.assert_called_once_with(encoding="utf-8")
            with patch.object(web, "VERSION", module.VERSION), patch.object(web, "snapshot", side_effect=lambda pane: pane):
                status, body = self.request("GET", "/api/panes")
            self.assertEqual(status, 200)
            self.assertEqual(json.loads(body)["version"], expected)

    def test_browser_size_stacks_detached_panes_and_skips_matching_windows(self):
        group = [dict(id="%" + str(index), session="team") for index in range(4)]
        for size, expected in (("80x24\n", 5), ("120x144\n", 3)):
            outcomes = ["", "%0\n%1\n%2\n%3\n", size, "", ""]
            with self.subTest(size=size), patch.object(web, "panes", return_value=group), patch.object(web, "tmux", side_effect=outcomes) as tmux, patch.object(web, "snapshot", side_effect=lambda pane: pane):
                status, body = self.request("GET", "/api/panes?cols=120&rows=35")
            self.assertEqual(status, 200)
            self.assertEqual(json.loads(body)["panes"], group)
            self.assertEqual(tmux.call_count, expected)
            self.assertEqual(tmux.call_args_list[0].args, ("list-clients", "-t", "=team"))
            if expected >= 3:
                self.assertEqual(tmux.call_args_list[1].args, ("list-panes", "-t", "team:agents"))
                self.assertEqual(tmux.call_args_list[2].args, ("display-message", "-p", "-t", "team:agents", "#{window_width}x#{window_height}"))
            if expected == 5:
                self.assertEqual(tmux.call_args_list[3].args, ("resize-window", "-t", "team:agents", "-x", "120", "-y", "144"))
                self.assertEqual(tmux.call_args_list[4].args, ("select-layout", "-t", "team:agents", "even-vertical"))

    def test_browser_size_attached_client_releases_manual_size_only_once(self):
        for mode, expected in (("manual\n", 4), ("latest\n", 2)):
            with self.subTest(mode=mode), patch.object(web, "tmux", side_effect=["client\n", mode, "", ""]) as tmux, patch.object(web, "snapshot", side_effect=lambda pane: pane):
                self.assertEqual(self.request("GET", "/api/panes?cols=120&rows=35")[0], 200)
            self.assertEqual(tmux.call_count, expected)
            self.assertEqual(tmux.call_args_list[1].args, ("show-options", "-wv", "-t", "team:agents", "window-size"))
            if expected == 4:
                self.assertEqual(tmux.call_args_list[2].args, ("set", "-w", "-t", "team:agents", "-u", "window-size"))
                self.assertEqual(tmux.call_args_list[3].args, ("select-layout", "-t", "team:agents", "main-vertical"))

    def test_browser_size_validation_and_poll_without_dimensions(self):
        for query in ("cols=10&rows=35", "cols=120&rows=abc", "cols=501&rows=35", "cols=120&rows=301", "cols=120&rows=4", "cols=120", "rows=35", "cols=&rows=35"):
            with self.subTest(query=query), patch.object(web, "tmux") as tmux:
                status, body = self.request("GET", "/api/panes?" + query)
            self.assertEqual(status, 400)
            self.assertIn("error", json.loads(body))
            tmux.assert_not_called()
        with patch.object(web, "tmux") as tmux, patch.object(web, "snapshot", side_effect=lambda pane: pane):
            self.assertEqual(self.request("GET", "/api/panes")[0], 200)
        tmux.assert_not_called()

    def test_browser_size_tmux_failures_leave_poll_available(self):
        group = [dict(id="%0", session="team"), dict(id="%1", session="other")]
        for index, failure in enumerate((subprocess.CalledProcessError(1, "tmux"), subprocess.TimeoutExpired("tmux", 5), OSError("tmux unavailable"))):
            with self.subTest(failure=failure), patch.object(web, "panes", return_value=group), patch.object(web, "tmux", side_effect=["", "%1\n", "80x24\n", failure, "client\n", "latest\n"]) as tmux, patch.object(web, "snapshot", side_effect=lambda pane: pane), contextlib.redirect_stderr(io.StringIO()) as error:
                status, body = self.request("GET", "/api/panes?cols=120&rows=35")
            self.assertEqual(status, 200)
            self.assertEqual(json.loads(body)["panes"], group)
            self.assertEqual(tmux.call_count, 6)
            self.assertEqual(len(error.getvalue().splitlines()), int(index == 0))
        self.assertEqual(self.server.resize_errors, {"other"})

    def test_browser_size_caps_total_window_height(self):
        with patch.object(web, "tmux", side_effect=["", "%0\n" * 40, "80x24\n", "", ""]) as tmux, patch.object(web, "snapshot", side_effect=lambda pane: pane):
            self.assertEqual(self.request("GET", "/api/panes?cols=120&rows=300")[0], 200)
        self.assertEqual(tmux.call_args_list[3].args, ("resize-window", "-t", "team:agents", "-x", "120", "-y", "10000"))

    def test_real_browser_measurement_uses_output_line_height(self):
        chrome = shutil.which("google-chrome") or shutil.which("chromium")
        if not chrome:
            self.skipTest("Chrome or Chromium is required for browser measurement")
        source = (ROOT / "web/app.js").read_text()
        span = source[source.index("const cellMeasure ="):source.index("let dragging =")]
        measure = source[source.index("async function refresh() {"):source.index('    const {panes, initial, version} = await api("/api/panes"')]
        script = '''const output = document.querySelector('.output');
const cards = new Map([['active', {id: '%2', lines: 1000, el: {hidden: false, querySelector: () => output}}]]);
let refreshTimer, refreshing = false, refreshRequested = false;
function currentPane() {return 'active';}
''' + span + measure + '''return parameters;} catch (error) {throw error;}}
refresh().then(parameters => {document.querySelector('#result').textContent = JSON.stringify({parameters, height: cellMeasure.getBoundingClientRect().height, lineHeight: parseFloat(getComputedStyle(output).lineHeight)});});'''
        with tempfile.TemporaryDirectory() as directory:
            html = Path(directory) / "measure.html"
            html.write_text('<!doctype html><style>' + (ROOT / "web/style.css").read_text() + '</style><pre class="output" style="width:640px;height:416px;flex:none;box-sizing:content-box"></pre><pre id="result"></pre><script>' + script + '</script>')
            process = subprocess.Popen([chrome, "--headless=new", "--no-sandbox", "--disable-gpu", "--no-first-run", "--no-default-browser-check", "--disable-extensions", "--disable-background-networking", "--disable-dev-shm-usage", "--virtual-time-budget=5000", "--dump-dom", "--user-data-dir=" + str(Path(directory) / "profile"), html.as_uri()], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
            try:
                stdout, stderr = process.communicate(timeout=60)
            except subprocess.TimeoutExpired:
                self.fail("Chrome timed out after 60 seconds")
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                    try:
                        process.communicate(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.stdout.close()
                        process.stderr.close()
            self.assertEqual(process.returncode, 0, stderr)
            result = json.loads(unescape(stdout.split('<pre id="result">', 1)[1].split('</pre>', 1)[0]))
            self.assertAlmostEqual(result["lineHeight"], 20.8, delta=0.02)
            self.assertAlmostEqual(result["height"], result["lineHeight"], delta=0.02)
            self.assertIn("rows=20", result["parameters"].split("&"))

    def test_real_tmux_browser_size_gives_each_pane_exact_content_dimensions(self):
        socket = "peon-web-size-check-" + str(os.getpid())
        session = "browser-size-check"
        def tmux(*args):
            return subprocess.run(["tmux", "-L", socket, "-f", "/dev/null", *args], capture_output=True, text=True, timeout=5, check=True).stdout
        try:
            tmux("new-session", "-d", "-s", session, "-n", "agents", "-x", "80", "-y", "60")
            tmux("set", "-w", "-t", session + ":agents", "pane-border-status", "top")
            for _ in range(3):
                tmux("split-window", "-t", session + ":agents")
                tmux("select-layout", "-t", session + ":agents", "tiled")
            group = [dict(id=pane, session=session) for pane in tmux("list-panes", "-t", session + ":agents", "-F", "#{pane_id}").splitlines()]
            with patch.object(web, "panes", return_value=group), patch.object(web, "tmux", side_effect=tmux), patch.object(web, "snapshot", side_effect=lambda pane: pane):
                self.assertEqual(self.request("GET", "/api/panes?cols=120&rows=35")[0], 200)
            self.assertEqual(tmux("list-panes", "-t", session + ":agents", "-F", "#{pane_width}x#{pane_height}").splitlines(), ["120x35"] * 4)
        finally:
            subprocess.run(["tmux", "-L", socket, "kill-session", "-t", "=" + session], capture_output=True, timeout=5)

    def test_terminal_attach_unsets_browser_size_before_attach_or_switch(self):
        with tempfile.TemporaryDirectory() as directory:
            fake = Path(directory) / "tmux"
            log = Path(directory) / "calls"
            fake.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$TEST_LOG"\ncase "$1" in\nshow-options) printf "%s\\n" "$TEST_MODE" ;;\nset|select-layout) exit "$TEST_FAILURE" ;;\nesac\n')
            fake.chmod(0o755)
            master, slave = pty.openpty()
            try:
                for attached, action, mode, failure in (("", "attach", "manual", "0"), ("existing-client", "switch-client", "manual", "0"), ("", "attach", "manual", "1"), ("", "attach", "latest", "0")):
                    log.write_text("")
                    environment = dict(os.environ, PATH=directory + os.pathsep + os.environ.get("PATH", ""), TEST_LOG=str(log), TMUX=attached, TEST_MODE=mode, TEST_FAILURE=failure)
                    result = subprocess.run(["bash", "-ec", 'source "$1/lib/session.sh"; goto_session team', "bash", str(ROOT)], stdin=slave, capture_output=True, text=True, timeout=5, env=environment, start_new_session=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    expected = ["show-options -wv -t team:agents window-size"]
                    if mode == "manual":
                        expected += ["set -w -t team:agents -u window-size", "select-layout -t team:agents main-vertical"]
                    self.assertEqual(log.read_text().splitlines(), expected + [action + " -t =team"])
            finally:
                os.close(slave)
                os.close(master)

    def test_buttons_list_create_and_duplicate(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(web, "BUTTONS_DIR", Path(directory) / "buttons"):
            self.assertEqual(json.loads(self.request("GET", "/api/buttons")[1]), [])
            web.BUTTONS_DIR.mkdir()
            saved = Path(self.config.name) / "peon-code" / "buttons"
            first = dict(name="Z check_1", description="Check the changes", prompt="It's `quoted` $(literal)\r\n日本語\n")
            second = dict(name="A-check", description="", prompt="Check again")
            for button, expected in ((first, [first]), (second, [second, first])):
                status, body = self.request("POST", "/api/buttons", button)
                self.assertEqual((status, json.loads(body)), (200, expected))
                self.assertEqual((saved / (button["name"] + ".md")).read_bytes().decode("utf-8"),
                                 "---\ndescription: " + button["description"] + "\n---\n" + button["prompt"])
                self.assertFalse((web.BUTTONS_DIR / (button["name"] + ".md")).exists())
            (web.BUTTONS_DIR / "Malformed.md").write_text("no frontmatter")
            (web.BUTTONS_DIR / "Invalid.name.md").write_text("---\ndescription: Invalid name\n---\nPrompt")
            (web.BUTTONS_DIR / "Dir.md").mkdir()
            (web.BUTTONS_DIR / "Dangling.md").symlink_to(web.BUTTONS_DIR / "missing")
            status, body = self.request("GET", "/api/buttons")
            self.assertEqual((status, json.loads(body)), (200, [second, first]))
            status, body = self.request("POST", "/api/buttons", dict(first, prompt="Overwrite"))
            self.assertEqual(status, 409)
            self.assertIn("error", json.loads(body))
            self.assertEqual(json.loads(self.request("GET", "/api/buttons")[1]), [second, first])

    def test_button_names_accept_ascii_apostrophes_only(self):
        names = [button["name"] for button in web.read_buttons()]
        self.assertIn("What's left", names)
        self.assertNotIn("What left", names)
        button = dict(name="Worker's tasks", description="List tasks", prompt="List open tasks")
        status, body = self.request("POST", "/api/buttons", button)
        self.assertEqual(status, 200)
        self.assertIn(button, json.loads(body))
        self.assertEqual(self.request("POST", "/api/buttons", dict(button, name="Worker’s tasks"))[0], 400)

    def test_buttons_order_and_optional_frontmatter(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(web, "BUTTONS_DIR", Path(directory)):
            files = {
                "Z default": "description: No order\n",
                "Z first": "order: 1\ndescription: Before\n",
                "A second": "description: After\norder: 2\n",
                "Z second": "order: 2\ndescription: Tie\n",
            }
            for name, header in files.items():
                (web.BUTTONS_DIR / (name + ".md")).write_bytes(("---\r\n" + header.replace("\n", "\r\n") + "---\r\nPrompt\r\n").encode())
            status, body = self.request("GET", "/api/buttons")
            buttons = json.loads(body)
            self.assertEqual(status, 200)
            self.assertEqual([button["name"] for button in buttons], list(files))
            self.assertNotIn("order", buttons[0])
            self.assertEqual([button.get("order", 0) for button in buttons], [0, 1, 2, 2])
            self.assertTrue(all(button["prompt"] == "Prompt\r\n" for button in buttons))
            explicit = dict(name="A saved", description="Explicit order", prompt="Keep\r\nthis\n", order=1)
            status, body = self.request("POST", "/api/buttons", explicit)
            self.assertEqual((status, json.loads(body)[1]), (200, explicit))
            saved = Path(self.config.name) / "peon-code" / "buttons" / "A saved.md"
            self.assertEqual(saved.read_bytes().decode(), "---\norder: 1\ndescription: Explicit order\n---\n" + explicit["prompt"])
            for order in (-1, 1001, True, 1.5, "1", None):
                with self.subTest(order=order):
                    self.assertEqual(self.request("POST", "/api/buttons", dict(explicit, name="Invalid", order=order))[0], 400)
            (web.BUTTONS_DIR / "Invalid.md").write_text("---\norder: 1001\ndescription: Invalid\n---\nPrompt")
            (web.BUTTONS_DIR / "Duplicate.md").write_text("---\norder: 1\ndescription: Duplicate\norder: 2\n---\nPrompt")
            self.assertEqual(json.loads(self.request("GET", "/api/buttons")[1]), [buttons[0], explicit, *buttons[1:]])

    def test_buttons_trim_spaces_and_read_crlf_without_changing_prompt(self):
        button = dict(name="Check", description="Check changes", prompt="Check this branch")
        crlf = dict(name="Windows", description="CRLF header", prompt="Line one\r\nLine two\n")
        with tempfile.TemporaryDirectory() as directory, patch.object(web, "BUTTONS_DIR", Path(directory)):
            status, body = self.request("POST", "/api/buttons", dict(button, name="  Check  "))
            self.assertEqual((status, json.loads(body)), (200, [button]))
            saved = Path(self.config.name) / "peon-code" / "buttons"
            self.assertTrue((saved / "Check.md").is_file())
            self.assertEqual(self.request("POST", "/api/buttons", dict(button, name=" Check "))[0], 409)
            (web.BUTTONS_DIR / "Windows.md").write_bytes(
                ("---\r\ndescription: " + crlf["description"] + "\r\n---\r\n" + crlf["prompt"]).encode("utf-8"))
            status, body = self.request("GET", "/api/buttons")
            self.assertEqual((status, json.loads(body)), (200, [button, crlf]))
            self.assertEqual(self.request("POST", "/api/buttons", crlf)[0], 409)
            self.assertFalse((saved / "Windows.md").exists())
            read = Path.read_bytes
            def read_or_deny(path):
                if path.name == "Check.md":
                    raise PermissionError("Cannot read button")
                return read(path)
            with patch.object(Path, "read_bytes", read_or_deny):
                status, body = self.request("GET", "/api/buttons")
                self.assertEqual((status, json.loads(body)), (200, [crlf]))

    def test_buttons_validation_and_authentication(self):
        valid = dict(name="Check", description="Check changes", prompt="Check this branch")
        with tempfile.TemporaryDirectory() as directory, patch.object(web, "BUTTONS_DIR", Path(directory)):
            for method in ("GET", "POST"):
                for headers in ({"X-Peon-Token": ""}, {"Host": "evil.test"}, {"Origin": "https://evil.test"}):
                    self.assertEqual(self.request(method, "/api/buttons", valid if method == "POST" else None, headers)[0], 403)
            invalid = [{"name": name} for name in ("../escape", "a/b", "a\\b", "a.md", "é", "x\n", " ", "", "x" * 81, 1, None)]
            invalid += [{"description": value} for value in ("two\nlines", "line\rbreak", "x" * 501, None, 1, "\ud800")]
            invalid += [{"prompt": value} for value in (" ", "", "x" * 200001, None, [], "\ud800")]
            for fields in invalid:
                with self.subTest(fields=fields):
                    self.assertEqual(self.request("POST", "/api/buttons", dict(valid, **fields))[0], 400)
            for data in ([], "text", 1, None, {}):
                self.assertEqual(self.request("POST", "/api/buttons", data)[0], 400)
            self.assertEqual(self.request("POST", "/api/buttons", dict(valid, padding="x" * 262144))[0], 400)
            self.assertEqual(self.request("POST", "/api/buttons", valid, {"Content-Type": "text/plain"})[0], 400)
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_buttons_concurrent_create_never_overwrites(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(web, "BUTTONS_DIR", Path(directory)):
            barrier, results = threading.Barrier(2), []
            def save(prompt):
                barrier.wait()
                status, _ = self.request("POST", "/api/buttons", dict(name="Same", description="", prompt=prompt))
                results.append((status, prompt))
            threads = [threading.Thread(target=save, args=(prompt,)) for prompt in ("First", "Second")]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join(timeout=5)
            self.assertEqual(sorted(status for status, _ in results), [200, 409])
            winner = next(prompt for status, prompt in results if status == 200)
            self.assertEqual(json.loads(self.request("GET", "/api/buttons")[1]),
                             [dict(name="Same", description="", prompt=winner)])

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
        keys = ("Tab", "Up", "Down", "Enter", "Escape", "Backspace")
        def deliver(args, text, identity):
            self.assertTrue(self.server.send_lock.locked())
            return subprocess.CompletedProcess(args, 0, "key sent", "")
        with patch.object(web, "run_delivery", side_effect=deliver) as run, patch.object(web, "snapshot") as snapshot:
            for key in keys:
                data = dict(pane="%2", identity="server:session:pane", key=key, text="Never send this text")
                status, body = self.request("POST", "/api/keys", data)
                self.assertEqual((status, json.loads(body)), (200, {"message": "key sent"}))
                flags = ["--submit"] if key == "Enter" else []
                run.assert_called_with([str(ROOT / "peon-code.sh"), "key", *flags, "%2", "BSpace" if key == "Backspace" else key], "", "server:session:pane")
            for key in (*"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ", "Esc", "tab", "BSpace", "backspace", "Bspace", "10", "aa", "é", "C-c", "Tab Enter", "", None, 1, []):
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

    def test_open_session_arguments_and_unfilters_polling(self):
        directory = "/project with spaces; $(literal)"
        for session in (None, "", "custom.team"):
            self.server.session = "team"
            data = dict(directory=directory)
            if session is not None:
                data["session"] = session
            with self.subTest(session=session), patch.object(web, "open_project", return_value="custom_team") as start:
                status, body = self.request("POST", "/api/open", data)
                self.assertEqual((status, json.loads(body)), (200, {"session": "custom_team"}))
                start.assert_called_once_with(SimpleNamespace(directory=directory, session=session or "", config=None), ROOT, timeout=300)
                self.assertIsNone(self.server.session)
                with patch.object(web, "snapshot", side_effect=lambda pane: pane), patch.object(web, "panes", return_value=[dict(id="%3", session="custom_team")]) as panes:
                    status, body = self.request("GET", "/api/panes")
                panes.assert_called_once_with(None)
                self.assertEqual(json.loads(body)["panes"][0]["session"], "custom_team")

    def test_open_uploads_are_private_unique_and_ignore_xdg(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(web.Path, "home", return_value=Path(directory)):
            uploads = Path(directory) / launch.REMOTE_CONFIG_DIR
            uploads.mkdir(parents=True)
            existing = uploads / "team.conf"
            existing.write_text("Keep this file")
            paths = []
            text = "codex codex -\r\n# 日本語\n"
            def launch_uploaded(args, root, timeout):
                self.assertEqual((args.directory, args.session, root, timeout), ("~/project", "", ROOT, 300))
                self.assertEqual(args.config.parent, uploads)
                self.assertEqual(args.config.read_bytes(), text.encode("utf-8"))
                self.assertEqual(args.config.stat().st_mode & 0o777, 0o600)
                paths.append(args.config)
                return "new_team"
            for _ in range(2):
                with patch.object(web, "open_project", side_effect=launch_uploaded):
                    status, body = self.request("POST", "/api/open", dict(directory="~/project", config_name="team.conf", config_text=text))
                self.assertEqual((status, json.loads(body)), (200, {"session": "new_team"}))
                self.assertFalse(paths[-1].exists())
            self.assertNotEqual(paths[0], paths[1])
            self.assertEqual(existing.read_text(), "Keep this file")
            self.assertFalse((Path(self.config.name) / "peon-code" / "uploads").exists())

    def test_open_validation_and_authentication(self):
        valid = dict(directory="/project")
        invalid = [dict(directory=value) for value in ("", " ", "\t\n", "x" * 4097, "bad\0path", "relative", "./relative", "-rf", 1, None, [])]
        invalid += [dict(directory=value, config_name="team.conf", config_text="team") for value in ("relative", "./relative", "-rf")]
        invalid += [dict(valid, session=value) for value in (None, 1, [], {}, "-option", "bad\nname", "bad\x7fname")]
        invalid += [dict(valid, session=value, config_name="team.conf", config_text="team") for value in ("-option", "bad\nname", "bad\x7fname")]
        invalid += [dict(valid, config_name="team.conf"), dict(valid, config_text="team")]
        invalid += [dict(valid, config_name=value, config_text="team") for value in ("", " ", ".", "..", "../team", "a/b", "a\\b", "a\0b", "a\nb", "a\x7fb", "\ud800", 1, None)]
        invalid += [dict(valid, config_name="team.conf", config_text=value) for value in (None, 1, [], "\ud800")]
        invalid += [[], "project", 1, None, {}]
        with tempfile.TemporaryDirectory() as directory, patch.object(web.Path, "home", return_value=Path(directory)), patch.object(web, "open_project") as start:
            for data in invalid:
                with self.subTest(data=data):
                    self.assertEqual(self.request("POST", "/api/open", data)[0], 400)
            for headers in ({"X-Peon-Token": ""}, {"Host": "evil.test"}, {"Origin": "https://evil.test"}, {"Content-Type": "text/plain"}):
                with self.subTest(headers=headers):
                    self.assertEqual(self.request("POST", "/api/open", valid, headers)[0], 400 if "Content-Type" in headers else 403)
            status, body = self.request("POST", "/api/open", valid, {"Content-Length": str(2 * 1024 * 1024 + 1)})
            self.assertEqual((status, json.loads(body)), (400, {"error": "Expected JSON, at most 2 MiB"}))
            start.assert_not_called()
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_open_config_limit_counts_utf8_bytes(self):
        paths = []
        def launch_uploaded(args, root, timeout):
            self.assertEqual(args.config.read_bytes(), text.encode("utf-8"))
            paths.append(args.config)
            return "team"
        with tempfile.TemporaryDirectory() as directory, patch.object(web.Path, "home", return_value=Path(directory)), patch.object(web, "open_project", side_effect=launch_uploaded) as start:
            for text in ("x" * (200 * 1024), "é" * (100 * 1024), "\n" * (150 * 1024), "\0" * (200 * 1024)):
                status, _ = self.request("POST", "/api/open", dict(directory="/project", config_name="team.conf", config_text=text))
                self.assertEqual(status, 200)
                self.assertFalse(paths[-1].exists())
            for text in ("x" * (200 * 1024 + 1), "é" * (100 * 1024 + 1)):
                status, body = self.request("POST", "/api/open", dict(directory="/project", config_name="team.conf", config_text=text))
                self.assertEqual(status, 400)
                self.assertIn("200 KiB", json.loads(body)["error"])
            self.assertEqual(start.call_count, 4)

    def test_open_project_and_launch_errors_preserve_filter(self):
        timeout = subprocess.TimeoutExpired("launch", 300, stderr="Run peon-code dismiss new_team before retrying.")
        byte_timeout = subprocess.TimeoutExpired("tmux", 5, stderr=b"partial output")
        for error, expected in ((RuntimeError("bad project"), 400), (OSError("launch failed"), 503), (timeout, 503), (byte_timeout, 503)):
            paths = []
            def fail_launch(args, root, timeout):
                self.assertEqual(args.config.read_bytes(), b"team")
                paths.append(args.config)
                raise error
            with self.subTest(error=error), patch.object(web, "open_project", side_effect=fail_launch), patch.object(web.Path, "home", return_value=Path(self.config.name)):
                status, body = self.request("POST", "/api/open", dict(directory="/project", config_name="team.conf", config_text="team"))
                self.assertEqual((status, json.loads(body)), (expected, {"error": error.stderr if error is timeout else str(error)}))
                self.assertEqual(len(paths), 1)
                self.assertFalse(paths[0].exists())
                self.assertEqual(self.server.session, "team")
        with patch.object(web.tempfile, "NamedTemporaryFile", side_effect=PermissionError("Cannot save config")), patch.object(web, "open_project") as start, patch.object(web.Path, "home", return_value=Path(self.config.name)):
            self.assertEqual(self.request("POST", "/api/open", dict(directory="/project", config_name="team.conf", config_text="team"))[0], 503)
            start.assert_not_called()

    def test_open_upload_write_failure_removes_file(self):
        create_file, paths = web.tempfile.NamedTemporaryFile, []
        @contextlib.contextmanager
        def fail_write(*args, **kwargs):
            with create_file(*args, **kwargs) as file:
                paths.append(Path(file.name))
                with patch.object(file, "write", side_effect=OSError("Cannot write config")):
                    yield file
        with patch.object(web.tempfile, "NamedTemporaryFile", side_effect=fail_write), patch.object(web.Path, "home", return_value=Path(self.config.name)), patch.object(web, "open_project") as start:
            status, body = self.request("POST", "/api/open", dict(directory="/project", config_name="team.conf", config_text="team"))
        self.assertEqual((status, json.loads(body)), (503, {"error": "Cannot write config"}))
        self.assertEqual(len(paths), 1)
        self.assertFalse(paths[0].exists())
        start.assert_not_called()

    def test_open_existing_session_removes_upload(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(web.Path, "home", return_value=Path(directory)):
            outcomes = [subprocess.CompletedProcess([], 0), subprocess.CompletedProcess([], 0, "1", ""), subprocess.CompletedProcess([], 0, directory + "\n", "")]
            with patch.object(web.subprocess, "run", side_effect=outcomes), patch.object(web.subprocess, "Popen") as popen, contextlib.redirect_stderr(io.StringIO()):
                status, body = self.request("POST", "/api/open", dict(directory=directory, session="existing", config_name="team.conf", config_text="team"))
            self.assertEqual((status, json.loads(body)), (200, {"session": "existing"}))
            self.assertEqual(list((Path(directory) / launch.REMOTE_CONFIG_DIR).iterdir()), [])
            popen.assert_not_called()

    def test_open_uses_shared_project_and_session_checks(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(web.subprocess, "run") as run:
            for session in ("-option", "bad\nname", "bad\x7fname"):
                with self.subTest(session=session):
                    self.assertEqual(self.request("POST", "/api/open", dict(directory=directory, session=session))[0], 400)
            self.assertEqual(self.request("POST", "/api/open", dict(directory="/"))[0], 400)
            self.assertEqual(self.request("POST", "/api/open", dict(directory=str(Path(directory) / "missing")))[0], 400)
            run.assert_not_called()

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

    def test_snapshot_joins_history_but_keeps_visible_screen_rows(self):
        pane = dict(id="%2", identity="100:$1:202")
        visible = "› wrapped input\ncontinues here\nHint below cursor\nwraps here\n"
        styled = "› wrapped input\ncontinues here\n\x1b[2mHint below cursor\nwraps here\x1b[0m\n"
        with patch.object(bridge, "tmux", side_effect=["› wrapped inputcontinues here\nHint below cursorwraps here\n", visible, styled, "", "0", "100:$1:202\t1500\t1\n"]) as tmux:
            result = bridge.snapshot(pane, 2000)
        self.assertEqual(tmux.call_args_list[0].args,
                         ("capture-pane", "-p", "-e", "-N", "-J", "-t", "%2", "-S", "-2000"))
        self.assertEqual(tmux.call_args_list[1].args, ("capture-pane", "-p", "-t", "%2"))
        self.assertEqual(tmux.call_args_list[2].args, ("capture-pane", "-p", "-e", "-N", "-t", "%2"))
        self.assertEqual(result["screen"], visible)
        self.assertEqual(result["styledScreen"], styled)
        self.assertEqual(result["cursorY"], 1)
        self.assertFalse(result["menu"])

    def test_panes_weekly_limit_values(self):
        for text, expected in (
                ("25.5 1700000000", {"usedPercent": 25.5, "resetsAt": 1700000000}),
                ("0 1700000000", {"usedPercent": 0.0, "resetsAt": 1700000000}),
                ("100.0 1700000000", {"usedPercent": 100.0, "resetsAt": 1700000000}),
                ("", None), ("malformed", None), ("25 1700000000 extra", None),
                ("NaN 1700000000", None), ("inf 1700000000", None),
                ("1e999 1700000000", None), ("-1 1700000000", None),
                ("101 1700000000", None), ("true 1700000000", None),
                ("25 true", None), ("25 1700000000.5", None),
                ("25 -1", None), ('"25" 1700000000', None)):
            rows = "team\t%2\tworker\t1\tcodex\tworker\t\t100:$1:202\t" + text + "\t\t\n"
            with self.subTest(text=text), patch.object(bridge.time, "time", return_value=1699999999), patch.object(bridge, "tmux", side_effect=[rows, "/work/project\n"]) as tmux:
                pane = bridge.panes()[0]
            self.assertEqual(pane["weekly"], expected)
            self.assertTrue(tmux.call_args_list[0].args[-1].endswith("\t#{@peon_weekly}\t#{@peon_usage}\t#{@peon_bin}"))
            if expected:
                self.assertIsInstance(pane["weekly"]["usedPercent"], float)
                self.assertIsInstance(pane["weekly"]["resetsAt"], int)

    def test_panes_weekly_reset_time(self):
        for resets, expected_used in ((1699999999, 0.0), (1700000000, 25.5), (1700000001, 25.5)):
            rows = "team\t%2\tworker\t1\tcodex\tworker\t\t100:$1:202\t25.5 " + str(resets) + "\t\t\n"
            with self.subTest(resets=resets), patch.object(bridge.time, "time", return_value=1700000000), patch.object(bridge, "tmux", side_effect=[rows, "/work/project\n"]):
                pane = bridge.panes()[0]
            self.assertEqual(pane["weekly"], {"usedPercent": expected_used, "resetsAt": resets})

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
                    "initial": expected_initial, "version": web.VERSION})

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

    def test_default_port_falls_back_with_notice_but_explicit_port_fails(self):
        server = Mock(server_port=9123)
        with patch.object(web, "ThreadingHTTPServer", side_effect=[self.error, server]) as bind, patch.object(web.os, "kill") as kill, contextlib.redirect_stderr(io.StringIO()) as error:
            self.assertIs(web.bind_server(None), server)
        self.assertEqual([call.args[0] for call in bind.call_args_list], [("127.0.0.1", 8765), ("127.0.0.1", 0)])
        self.assertEqual(error.getvalue(), "port 8765 is busy, using 9123\n")
        kill.assert_not_called()
        with patch.object(web, "ThreadingHTTPServer", side_effect=self.error) as bind, self.assertRaises(OSError) as raised:
            web.bind_server(8765)
        self.assertIs(raised.exception, self.error)
        self.assertEqual(bind.call_count, 1)

    def test_default_port_does_not_fall_back_for_other_bind_errors(self):
        error = OSError(errno.EACCES, "permission denied")
        with patch.object(web, "ThreadingHTTPServer", side_effect=error) as bind, self.assertRaises(OSError) as raised:
            web.bind_server(None)
        self.assertIs(raised.exception, error)
        self.assertEqual(bind.call_count, 1)

    def test_real_busy_default_binds_another_loopback_port(self):
        with web.socket.socket() as occupied:
            occupied.bind(("127.0.0.1", 0))
            occupied.listen(1)
            port = occupied.getsockname()[1]
            with patch.object(web, "DEFAULT_PORT", port), contextlib.redirect_stderr(io.StringIO()) as error:
                server = web.bind_server(None)
            try:
                self.assertNotEqual(server.server_port, port)
                self.assertEqual(server.server_address[0], "127.0.0.1")
                self.assertEqual(error.getvalue(), f"port {port} is busy, using {server.server_port}\n")
                with self.assertRaises(OSError):
                    web.bind_server(port)
            finally:
                server.server_close()

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

    def test_default_port_replaces_stale_server_before_considering_fallback(self):
        self.path.write_text("12345\n")
        server = Mock(server_port=8765)
        with patch.object(web, "ThreadingHTTPServer", side_effect=[self.error, server]) as bind, patch.object(web.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "python /project/web/server.py --stdio\n", "")), patch.object(web.os, "kill") as kill, patch.object(web.socket, "create_connection", side_effect=ConnectionRefusedError), contextlib.redirect_stderr(io.StringIO()) as error:
            self.assertIs(web.bind_server(None), server)
        self.assertEqual([call.args[0] for call in bind.call_args_list], [("127.0.0.1", 8765)] * 2)
        kill.assert_called_once_with(12345, signal.SIGTERM)
        self.assertEqual(error.getvalue(), "")

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
