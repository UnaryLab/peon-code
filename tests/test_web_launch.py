import contextlib
import io
import json
import os
import shlex
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'web'))
import launch


class LaunchTests(unittest.TestCase):
    def test_ssh_command_quotes_sessions_and_binds_loopback(self):
        session = "team 'quoted'; $(touch /tmp/nope)"
        args = SimpleNamespace(port=9123, session=session, ssh='user@host', directory=None)
        command = launch.ssh_command(args)
        self.assertEqual(command[:8], ['ssh', '-T', '-o', 'ExitOnForwardFailure=yes', '-L', '127.0.0.1:9123:127.0.0.1:9123', '--', 'user@host'])
        remote_args = shlex.split(command[-1].split('exec peon-code-web ', 1)[1].split('; else', 1)[0])
        self.assertEqual(remote_args[-1], session)
        self.assertIn('"$HOME/.local/bin/peon-code-web"', command[-1])

    def test_rejects_ssh_option_or_shell_injection(self):
        for host in ('-oProxyCommand=bad', 'host;touch /tmp/nope', 'host\ncommand'):
            with patch.object(sys, 'argv', ['peon-code-web', '--ssh', host]), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                launch.arguments()

    def test_real_stdio_server_stops_when_client_closes(self):
        process = subprocess.Popen([sys.executable, str(ROOT / 'web/server.py'), '--stdio', '--no-open', '--port', '0'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            url = json.loads(process.stdout.readline())['url']
            from http.client import HTTPConnection
            from urllib.parse import urlsplit
            parsed = urlsplit(url)
            connection = HTTPConnection(parsed.hostname, parsed.port, timeout=3)
            connection.request('GET', '/')
            response = connection.getresponse()
            self.assertEqual(response.status, 200)
            response.read(); connection.close()
            process.stdin.close(); process.stdin = None
            process.communicate(timeout=5)
            self.assertEqual(process.returncode, 0)
        finally:
            if process.poll() is None:
                process.kill(); process.communicate()

    def test_one_command_ssh_opens_local_browser_without_local_tmux(self):
        with tempfile.TemporaryDirectory() as directory:
            fake = Path(directory) / 'ssh'
            fake.write_text('#!/bin/sh\nprintf \'%s\\n\' \'{"url":12}\' \'{"url":"http://evil.test/#ignored"}\' \'{"url":"http://127.0.0.1:9123/#' + 'a' * 43 + '"}\'\nexit 0\n')
            fake.chmod(0o755)
            args = SimpleNamespace(port=9123, session=None, ssh='host', no_open=False, directory=None)
            with patch.dict(os.environ, {'PATH': directory}), patch.object(launch, 'open_browser') as opened, contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(launch.remote_ui(args), 0)
                self.assertEqual(opened.call_count, 1)

    def test_remote_directory_options_precede_literal_session(self):
        directory = "~/project with spaces; $(not-a-command)"
        args = SimpleNamespace(port=9123, session="new team", ssh="host", directory=directory)
        remote = launch.ssh_command(args)[-1]
        values = shlex.split(remote.split("exec peon-code-web ", 1)[1].split("; else", 1)[0])
        self.assertEqual(values[-4:], ["--dir", directory, "--", "new team"])

    def test_closed_remote_stdin_still_cleans_up_ssh(self):
        with tempfile.TemporaryDirectory() as directory:
            fake = Path(directory) / 'ssh'
            fake.write_text('#!/bin/sh\nexec 0<&-\nprintf \'%s\\n\' \'{"update":2,"host":"remote-test"}\'\nexec /bin/sleep 10\n')
            fake.chmod(0o755)
            args = SimpleNamespace(port=9123, session=None, ssh='host', no_open=False, directory=None)
            started = []
            popen = subprocess.Popen
            def start(*values, **options):
                process = popen(*values, **options)
                started.append(process)
                return process
            try:
                with patch.dict(os.environ, {'PATH': directory}), patch.object(launch.subprocess, 'Popen', side_effect=start), patch.object(sys, 'stdin', SimpleNamespace(isatty=lambda: False)), patch.object(launch, 'open_browser') as opened, self.assertRaises(BrokenPipeError):
                    launch.remote_ui(args)
                opened.assert_not_called()
                self.assertIsNotNone(started[0].poll())
                self.assertTrue(started[0].stdout.closed)
            finally:
                for process in started:
                    if process.poll() is None:
                        process.kill(); process.wait()
                    process.stdout.close()

    def test_create_or_open_project_safely(self):
        with tempfile.TemporaryDirectory(prefix="peon project quoted ") as directory:
            args = SimpleNamespace(session="new.team", directory=directory)
            with patch.object(launch.subprocess, "run", side_effect=[subprocess.CompletedProcess([], 1), subprocess.CompletedProcess([], 0, "ready", ""), subprocess.CompletedProcess([], 0, "1", ""), subprocess.CompletedProcess([], 0, directory + "\n", "")]) as run, contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(launch.open_project(args, ROOT), "new_team")
                self.assertEqual(run.call_args_list[1].args[0], [str(ROOT / "peon-code.sh"), "new_team"])
                self.assertEqual(run.call_args_list[1].kwargs["cwd"], str(Path(directory).resolve()))
                self.assertEqual(run.call_args_list[1].kwargs["stdin"], subprocess.DEVNULL)
            outcomes = [subprocess.CompletedProcess([], 0), subprocess.CompletedProcess([], 0, "1\n", ""), subprocess.CompletedProcess([], 0, directory + "\n", "")]
            with patch.object(launch.subprocess, "run", side_effect=outcomes) as run:
                self.assertEqual(launch.open_project(args, ROOT), "new_team")
                self.assertEqual(run.call_count, 3)
                self.assertIn("#{session_path}", run.call_args.args[0][-1])
            for marker, folder, error in [("", directory, "not a peon-code"), ("1", "/wrong/project", "different project")]:
                outcomes = [subprocess.CompletedProcess([], 0), subprocess.CompletedProcess([], 0, marker, ""), subprocess.CompletedProcess([], 0, folder, "")]
                with patch.object(launch.subprocess, "run", side_effect=outcomes), self.assertRaisesRegex(RuntimeError, error):
                    launch.open_project(args, ROOT)

    def test_directory_derives_remote_expanded_basename(self):
        with tempfile.TemporaryDirectory() as home:
            project = Path(home) / "my project.name"
            project.mkdir()
            with patch.object(sys, "argv", ["peon-code-web", "--dir", "~/my project.name/"]):
                args = launch.arguments()
            with patch.dict(os.environ, {"HOME": home}), patch.object(launch.subprocess, "run", side_effect=[subprocess.CompletedProcess([], 1), subprocess.CompletedProcess([], 0, "", ""), subprocess.CompletedProcess([], 0, "1", ""), subprocess.CompletedProcess([], 0, str(project) + "\n", "")]) as run, contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(launch.open_project(args, ROOT), "my project_name")
                self.assertEqual(run.call_args_list[1].kwargs["cwd"], str(project))
            args.directory = "/"
            with self.assertRaisesRegex(RuntimeError, "basename"):
                launch.open_project(args, ROOT)

    def test_creation_race_checks_final_project(self):
        with tempfile.TemporaryDirectory() as directory:
            outcomes = [subprocess.CompletedProcess([], 1), subprocess.CompletedProcess([], 0, "", ""), subprocess.CompletedProcess([], 0, "1", ""), subprocess.CompletedProcess([], 0, "/other/project\n", "")]
            with patch.object(launch.subprocess, "run", side_effect=outcomes), contextlib.redirect_stderr(io.StringIO()), self.assertRaisesRegex(RuntimeError, "different project"):
                launch.open_project(SimpleNamespace(session="race", directory=directory), ROOT)

    def test_removed_start_option_and_bad_directory(self):
        for options in (["--dir", ""], ["--ssh", "host", "--dir", ""]):
            with patch.object(sys, "argv", ["peon-code-web"] + options), contextlib.redirect_stderr(io.StringIO()) as error, self.assertRaises(SystemExit):
                launch.arguments()
            self.assertIn("non-empty project path", error.getvalue())
        with patch.object(sys, "argv", ["peon-code-web", "--start-session", "--dir", "/tmp"]), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            launch.arguments()
        with self.assertRaisesRegex(RuntimeError, "does not exist"):
            launch.open_project(SimpleNamespace(session=None, directory="/does/not/exist/peon-test"), ROOT)

    def test_reserved_names_only_link_verified_existing_sessions(self):
        with tempfile.TemporaryDirectory() as directory:
            for name in ("uninstall", "dismiss", "resume", "list", "clear", "send", "msg", "watch", "detach", "explain", "rebrief", "compact"):
                args = SimpleNamespace(session=name, directory=directory)
                with self.subTest(name=name), patch.object(launch.subprocess, "run", return_value=subprocess.CompletedProcess([], 1)) as run, self.assertRaisesRegex(RuntimeError, "peon-code command"):
                    launch.open_project(args, ROOT)
                self.assertEqual(run.call_count, 1)
            outcomes = [subprocess.CompletedProcess([], 0), subprocess.CompletedProcess([], 0, "1", ""), subprocess.CompletedProcess([], 0, directory + "\n", "")]
            with patch.object(launch.subprocess, "run", side_effect=outcomes):
                self.assertEqual(launch.open_project(SimpleNamespace(session="uninstall", directory=directory), ROOT), "uninstall")

    def test_ssh_update_handshake_prompts_locally_or_defaults_no(self):
        for interactive, reply in ((True, 'y'), (False, 'n')):
            with self.subTest(interactive=interactive), tempfile.TemporaryDirectory() as directory:
                result = Path(directory) / 'reply'
                fake = Path(directory) / 'ssh'
                fake.write_text('#!/bin/sh\nprintf \'%s\\n\' \'{"update":true,"host":"remote-test"}\' \'{"update":2,"host":"bad\\nhost"}\' \'{"update":2,"host":"remote-test"}\'\nIFS= read -r reply\nprintf \'%s\' "$reply" > ' + shlex.quote(str(result)) + '\nprintf \'%s\\n\' \'{"url":"http://127.0.0.1:9123/#' + 'a' * 43 + '"}\'\n')
                fake.chmod(0o755)
                args = SimpleNamespace(port=9123, session=None, ssh='host', no_open=False, directory=None)
                with patch.dict(os.environ, {'PATH': directory}), patch.object(sys, 'stdin', SimpleNamespace(isatty=lambda: interactive)), patch('builtins.input', return_value='yes') as prompt, patch.object(launch, 'open_browser') as opened, contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(launch.remote_ui(args), 0)
                    opened.assert_called_once()
                    if interactive:
                        prompt.assert_called_once_with('Remote peon-code on remote-test: update available upstream; pull now? [y/N] ')
                    else:
                        prompt.assert_not_called()
                self.assertEqual(result.read_text(), reply)


if __name__ == '__main__':
    unittest.main()
