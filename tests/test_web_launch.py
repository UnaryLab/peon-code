import contextlib
import errno
import io
import json
import os
import shlex
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'web'))
import launch


class LaunchTests(unittest.TestCase):
    def test_port_choice_preserves_omitted_default_and_validates_explicit_ports(self):
        for options, expected in (([], None), (["--ssh", "host"], None), (["--port", "0"], 0), (["--port", "65535"], 65535)):
            with self.subTest(options=options), patch.object(sys, "argv", ["peon-code-web"] + options):
                self.assertEqual(launch.arguments().port, expected)
        for options in (["--port", "-1"], ["--port", "65536"], ["--ssh", "host", "--port", "0"]):
            with self.subTest(options=options), patch.object(sys, "argv", ["peon-code-web"] + options), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                launch.arguments()

    def test_config_requires_directory_and_local_file(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "team.conf"
            config.write_text("codex codex -\n")
            for options, message in [
                (["--config", str(config)], "--config requires --dir"),
                (["--dir", directory, "--config", str(config) + ".missing"], "Config file does not exist"),
                (["--ssh", "host", "--dir", "/remote/project", "--config", str(config) + ".missing"], "Config file does not exist"),
                (["--dir", directory, "--config", directory], "Config file does not exist"),
            ]:
                with self.subTest(options=options), patch.object(sys, "argv", ["peon-code-web"] + options), contextlib.redirect_stderr(io.StringIO()) as error, self.assertRaises(SystemExit):
                    launch.arguments()
                self.assertIn(message, error.getvalue())
            with patch.dict(os.environ, {"HOME": directory}), patch.object(sys, "argv", ["peon-code-web", "--dir", "/remote/project", "--ssh", "host", "--config", "~/team.conf"]):
                self.assertEqual(launch.arguments().config, config.resolve())

    def test_config_resolves_before_project_launch_and_existing_team_warns(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory) / "project"
            project.mkdir()
            config = Path(directory) / "team.conf"
            config.write_text("codex codex -\n")
            relative = os.path.relpath(config)
            with patch.object(sys, "argv", ["peon-code-web", "--dir", str(project), "--config", relative, "custom"]):
                args = launch.arguments()
            self.assertEqual(args.config, config.resolve())
            outcomes = [subprocess.CompletedProcess([], 1), subprocess.CompletedProcess([], 0, "", ""), subprocess.CompletedProcess([], 0, "1", ""), subprocess.CompletedProcess([], 0, str(project) + "\n", "")]
            with patch.object(launch.subprocess, "run", side_effect=outcomes) as run, contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(launch.open_project(args, ROOT), "custom")
            self.assertEqual(run.call_args_list[1].args[0], [str(ROOT / "peon-code.sh"), "-c", str(config.resolve()), "custom"])
            self.assertEqual(run.call_args_list[1].kwargs["cwd"], str(project))
            outcomes = [subprocess.CompletedProcess([], 0), subprocess.CompletedProcess([], 0, "1", ""), subprocess.CompletedProcess([], 0, str(project) + "\n", "")]
            with patch.object(launch.subprocess, "run", side_effect=outcomes) as run, contextlib.redirect_stderr(io.StringIO()) as error:
                self.assertEqual(launch.open_project(args, ROOT), "custom")
            self.assertEqual(run.call_count, 3)
            self.assertEqual(error.getvalue(), "session custom already runs; --config applies only to a new team\n")

    def test_ssh_config_upload_is_private_and_uses_safe_remote_path(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "team.conf"
            config.write_bytes(b"codex codex -\n# bytes: \xff\n")
            for session, project, filename in [
                (None, "~/project with spaces///", "project_with_spaces.conf"),
                ("team/name; $x", "/remote/project", "team_name___x.conf"),
                ("..", "/remote/project", "...conf"),
                (None, "/", "team.conf"),
            ]:
                args = SimpleNamespace(port=9123, session=session, ssh="user@host", directory=project, config=config, no_open=True)
                with self.subTest(session=session, project=project), patch.object(launch.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, b"", b"")) as run, patch.object(launch.subprocess, "Popen") as popen, contextlib.redirect_stdout(io.StringIO()):
                    process = popen.return_value
                    process.stdout = io.StringIO(json.dumps({"url": "http://127.0.0.1:9123/#" + "a" * 43}) + "\n")
                    process.wait.return_value = 0
                    process.poll.return_value = 0
                    self.assertEqual(launch.remote_ui(args), 0)
                command = f'umask 077; mkdir -p "$HOME/.config/peon-code/uploads" && cat > "$HOME/.config/peon-code/uploads/{filename}" && chmod 600 "$HOME/.config/peon-code/uploads/{filename}"'
                run.assert_called_once_with(["ssh", "-T", "--", "user@host", command], input=config.read_bytes(), capture_output=True, timeout=30)
                popen.assert_called_once()
                self.assertEqual(popen.call_args.args[0][-2], "user@host")
                remote = popen.call_args.args[0][-1]
                values = shlex.split(remote.split("exec peon-code-web ", 1)[1].split("; else", 1)[0])
                self.assertEqual(values[values.index("--config") + 1], "~/.config/peon-code/uploads/" + filename)
                self.assertEqual(args.config, config)

    def test_failed_config_copy_prevents_ssh_server_start(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "team.conf"
            config.write_text("codex codex -\n")
            args = SimpleNamespace(port=9123, session=None, ssh="host", directory="/remote/project", config=config, no_open=True)
            with patch.object(launch.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, b"", b"Permission denied\n")), patch.object(launch.subprocess, "Popen") as popen, self.assertRaisesRegex(RuntimeError, "Permission denied"):
                launch.remote_ui(args)
            popen.assert_not_called()
            with patch.object(launch.subprocess, "run", side_effect=subprocess.TimeoutExpired("ssh", 30)), patch.object(launch.subprocess, "Popen") as popen, self.assertRaisesRegex(RuntimeError, "timed out"):
                launch.remote_ui(args)
            popen.assert_not_called()

    def test_ssh_command_quotes_sessions_and_binds_loopback(self):
        session = "team 'quoted'; $(touch /tmp/nope)"
        args = SimpleNamespace(port=9123, session=session, ssh='user@host', directory=None)
        command = launch.ssh_command(args)
        self.assertEqual(command[:8], ['ssh', '-T', '-o', 'ExitOnForwardFailure=yes', '-L', '127.0.0.1:9123:127.0.0.1:9123', '--', 'user@host'])
        remote_args = shlex.split(command[-1].split('exec peon-code-web ', 1)[1].split('; else', 1)[0])
        self.assertEqual(remote_args[-1], session)
        self.assertIn('"$HOME/.local/bin/peon-code-web"', command[-1])

    def test_ssh_default_adapts_only_local_forward_and_rewrites_validated_url(self):
        for port, busy, local in ((None, False, 8765), (None, True, 9123), (9123, False, 9123)):
            remote = port if port is not None else 8765
            args = SimpleNamespace(port=port, session=None, ssh="host", no_open=False, directory=None)
            with self.subTest(port=port, busy=busy), patch.object(launch.socket, "socket") as socket, patch.object(launch.subprocess, "Popen") as popen, patch.object(launch, "open_browser") as opened, contextlib.redirect_stdout(io.StringIO()) as output, contextlib.redirect_stderr(io.StringIO()) as error:
                probe = socket.return_value.__enter__.return_value
                probe.bind.side_effect = [OSError(errno.EADDRINUSE, "address in use"), None] if busy else None
                probe.getsockname.return_value = ("127.0.0.1", local)
                process = popen.return_value
                urls = ["http://evil.test/#" + "a" * 43]
                if busy:
                    urls.append(f"http://127.0.0.1:{local}/#" + "a" * 43)
                urls.append(f"http://127.0.0.1:{remote}/#" + "b" * 43)
                process.stdout = io.StringIO("".join(json.dumps({"url": url}) + "\n" for url in urls))
                process.wait.return_value = 0
                process.poll.return_value = 0
                self.assertEqual(launch.remote_ui(args), 0)
            command = popen.call_args.args[0]
            self.assertEqual(command[5], f"127.0.0.1:{local}:127.0.0.1:{remote}")
            remote_args = shlex.split(command[-1].split("exec peon-code-web ", 1)[1].split("; else", 1)[0])
            self.assertEqual(remote_args[remote_args.index("--port") + 1], str(remote))
            url = f"http://127.0.0.1:{local}/#" + "b" * 43
            opened.assert_called_once_with(url)
            self.assertIn("peon-code-web: " + url + "\n", output.getvalue())
            self.assertEqual(error.getvalue(), f"local port 8765 is busy, using {local}\n" if busy else "")
            if port is None:
                probe.setsockopt.assert_called_once_with(launch.socket.SOL_SOCKET, launch.socket.SO_REUSEADDR, 1)
                self.assertEqual([call[0] for call in probe.method_calls[:2]], ["setsockopt", "bind"])
                self.assertEqual([call.args[0] for call in probe.bind.call_args_list], [("127.0.0.1", 8765)] + ([("127.0.0.1", 0)] if busy else []))
                socket.return_value.__exit__.assert_called_once()
            else:
                socket.assert_not_called()

    def test_ssh_default_does_not_hide_other_socket_errors(self):
        args = SimpleNamespace(port=None, session=None, ssh="host", no_open=True, directory=None)
        with patch.object(launch.socket, "socket") as socket, patch.object(launch.subprocess, "Popen") as popen, self.assertRaises(PermissionError):
            socket.return_value.__enter__.return_value.bind.side_effect = PermissionError(errno.EACCES, "permission denied")
            launch.remote_ui(args)
        popen.assert_not_called()

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

    def test_optional_browser_timeout_uses_own_process_group(self):
        with tempfile.TemporaryDirectory() as directory:
            args = SimpleNamespace(session="browser", directory=directory)
            outcomes = [subprocess.CompletedProcess([], 1), subprocess.CompletedProcess([], 0, "1", ""), subprocess.CompletedProcess([], 0, directory + "\n", "")]
            process = Mock(returncode=0)
            process.communicate.return_value = ("ready", "")
            with patch.object(launch.subprocess, "run", side_effect=outcomes) as run, patch.object(launch.subprocess, "Popen", return_value=process) as popen, contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(launch.open_project(args, ROOT, timeout=300), "browser")
            popen.assert_called_once_with([str(ROOT / "peon-code.sh"), "browser"], cwd=directory, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
            process.communicate.assert_called_once_with(timeout=300)
            self.assertTrue(all(call.args[0][0] == "tmux" for call in run.call_args_list))
            process = Mock(pid=1234)
            error = subprocess.TimeoutExpired("launch", 300)
            process.communicate.side_effect = [error, ("", "")]
            with patch.object(launch.subprocess, "run", return_value=subprocess.CompletedProcess([], 1)), patch.object(launch.subprocess, "Popen", return_value=process), patch.object(launch.os, "killpg") as kill, contextlib.redirect_stderr(io.StringIO()), self.assertRaises(subprocess.TimeoutExpired) as raised:
                launch.open_project(args, ROOT, timeout=300)
            self.assertIs(raised.exception, error)
            self.assertEqual(error.stderr, "Team startup timed out for session 'browser'. Run peon-code dismiss browser before retrying.")
            kill.assert_called_once_with(process.pid, signal.SIGKILL)
            self.assertEqual([call.kwargs for call in process.communicate.call_args_list], [dict(timeout=300), {}])
            outcomes = [subprocess.CompletedProcess([], 0), subprocess.CompletedProcess([], 0, "1", ""), subprocess.CompletedProcess([], 0, directory + "\n", "")]
            with patch.object(launch.subprocess, "run", side_effect=outcomes), patch.object(launch.subprocess, "Popen") as popen:
                self.assertEqual(launch.open_project(args, ROOT, timeout=300), "browser")
            popen.assert_not_called()

    def test_browser_timeout_names_normalized_session_and_quotes_dismiss(self):
        with tempfile.TemporaryDirectory() as directory:
            args = SimpleNamespace(session="team.name:with 'quotes'", directory=directory)
            process = Mock(pid=1234)
            process.communicate.side_effect = [subprocess.TimeoutExpired("launch", 300), ("", "")]
            with patch.object(launch.subprocess, "run", return_value=subprocess.CompletedProcess([], 1)) as run, patch.object(launch.subprocess, "Popen", return_value=process), patch.object(launch.os, "killpg"), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(subprocess.TimeoutExpired) as raised:
                launch.open_project(args, ROOT, timeout=300)
            session = "team_name_with 'quotes'"
            self.assertIn(repr(session), raised.exception.stderr)
            self.assertIn("Run " + shlex.join(["peon-code", "dismiss", session]) + " before retrying", raised.exception.stderr)
            run.assert_called_once_with(["tmux", "has-session", "-t", "=" + session], capture_output=True, timeout=5)

    def test_browser_timeout_stops_real_launcher_child(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            marker = root / "late-output"
            script = root / "peon-code.sh"
            script.write_text('#!/bin/sh\nprintf started\\n\nsleep 0.5\nprintf late > ' + shlex.quote(str(marker)) + '\n')
            script.chmod(0o700)
            real_popen, started = launch.subprocess.Popen, []
            def start(*args, **kwargs):
                process = real_popen(*args, **kwargs)
                started.append(process)
                return process
            with patch.object(launch.subprocess, "run", return_value=subprocess.CompletedProcess([], 1)), patch.object(launch.subprocess, "Popen", side_effect=start), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(subprocess.TimeoutExpired):
                launch.open_project(SimpleNamespace(directory=directory, session="browser"), root, timeout=0.2)
            self.assertEqual(len(started), 1)
            self.assertEqual(started[0].returncode, -signal.SIGKILL)
            self.assertTrue(started[0].stdout.closed)
            self.assertTrue(started[0].stderr.closed)
            time.sleep(0.6)
            self.assertFalse(marker.exists())

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
            for name in ("uninstall", "dismiss", "resume", "list", "clear", "send", "key", "msg", "watch", "detach", "explain", "rebrief", "compact"):
                args = SimpleNamespace(session=name, directory=directory)
                with self.subTest(name=name), patch.object(launch.subprocess, "run", return_value=subprocess.CompletedProcess([], 1)) as run, self.assertRaisesRegex(RuntimeError, "peon-code command"):
                    launch.open_project(args, ROOT)
                self.assertEqual(run.call_count, 1)
            outcomes = [subprocess.CompletedProcess([], 0), subprocess.CompletedProcess([], 0, "1", ""), subprocess.CompletedProcess([], 0, directory + "\n", "")]
            for name in ("uninstall", "key"):
                with self.subTest(name=name), patch.object(launch.subprocess, "run", side_effect=outcomes):
                    self.assertEqual(launch.open_project(SimpleNamespace(session=name, directory=directory), ROOT), name)

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
