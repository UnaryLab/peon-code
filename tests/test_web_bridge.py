import sys
import os
import subprocess
import time
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'web'))
import bridge


class BridgeTests(unittest.TestCase):
    def test_scopes_order_and_existing_brief(self):
        with tempfile.TemporaryDirectory() as directory:
            brief = Path(directory) / 'brief.md'
            brief.write_text('Your role: archie, type reviewer: check the work\n')
            rows = f'team\t%5\timpl\t1\tcodex\tworker\t\t100:$1:205\nteam\t%2\tarchie\t1\tclaude\t\t{brief}\t100:$1:202\nteam\t%3\tboss\t1\tclaude\tmanager\t\t100:$1:203\nother\t%4\tone\t1\tcodex\t\t\t100:$2:204\nforeign\t%9\tx\t\tcodex\t\t\t100:$3:209\n'
            with patch.object(bridge, 'tmux', return_value=rows):
                panes = bridge.panes('team')
                self.assertEqual([p['id'] for p in panes], ['%3', '%2', '%5'])
                self.assertEqual([p['role'] for p in panes], ['manager', 'reviewer', 'worker'])
                self.assertEqual(len(bridge.panes()), 4)

    def test_roleless_default_order(self):
        rows = 'team\t%3\tthree\t1\tcodex\t\t\t100:$1:203\nteam\t%1\tone\t1\tcodex\t\t\t100:$1:201\nteam\t%2\ttwo\t1\tcodex\t\t\t100:$1:202\n'
        with patch.object(bridge, 'tmux', return_value=rows):
            self.assertEqual([(p['id'], p['role']) for p in bridge.panes()], [('%1', 'manager'), ('%2', 'reviewer'), ('%3', 'worker')])

    def test_project_directory_preserves_whitespace(self):
        project = '/work/project with spaces\tand\nnewlines '
        rows = 'team\t%1\tone\t1\tcodex\tmanager\t\t100:$1:201\n'
        with patch.object(bridge, 'tmux', side_effect=[rows, project + '\n']):
            self.assertEqual(bridge.panes()[0]['projectDir'], project)

    def test_closed_pane_during_discovery_is_skipped(self):
        rows = 'team\t%1\tone\t1\tcodex\tmanager\t\t100:$1:201\nteam\t%2\ttwo\t1\tcodex\tworker\t\t100:$1:202\n'
        with patch.object(bridge, 'tmux', side_effect=[rows, subprocess.CalledProcessError(1, 'tmux'), '/work/project\n']):
            self.assertEqual([pane['id'] for pane in bridge.panes()], ['%2'])

    def test_capture_keeps_ansi_and_background(self):
        pane = {'id': '%2', 'identity': '100:$1:202'}
        with patch.object(bridge, 'tmux', side_effect=['\x1b[38;2;1;2;3mtext\x1b[0m', 'fg=#abcdef,bg=#123456\n', '0', '100:$1:202\n']) as tmux:
            bridge.snapshot(pane)
        self.assertIn('-e', tmux.call_args_list[0].args)
        self.assertEqual(pane['defaultStyle'], 'fg=#abcdef,bg=#123456')
        self.assertIn('\x1b[', pane['output'])

    def test_real_tmux_inherited_background_and_truecolor(self):
        socket = 'peon-web-style-check-' + str(os.getpid())
        def tmux(*args):
            return subprocess.run(['tmux', '-L', socket, *args], capture_output=True, text=True, check=True, timeout=5).stdout
        try:
            tmux('-f', '/dev/null', 'new-session', '-d', '-s', 'style-check', "printf '\\033[38;2;200;30;40mCOLOUR\\033[0m\\n'; sleep 5")
            pane = tmux('display-message', '-p', '-t', 'style-check', '#{pane_id}').strip()
            tmux('set-window-option', '-t', 'style-check', 'window-style', 'fg=#abcdef,bg=#123456')
            result = {'id': pane, 'identity': tmux('display-message', '-p', '-t', pane, '#{pid}:#{session_id}:#{pane_pid}').strip()}
            with patch.object(bridge, 'tmux', side_effect=tmux):
                for _ in range(20):
                    bridge.snapshot(result)
                    if 'COLOUR' in result['output']:
                        break
                    time.sleep(.05)
            self.assertIn('\x1b[38;2;200;30;40m', result['output'])
            self.assertIn('bg=#123456', result['defaultStyle'])
        finally:
            subprocess.run(['tmux', '-L', socket, 'kill-session', '-t', 'style-check'], capture_output=True)

    def test_real_tmux_reused_id_has_new_identity(self):
        socket = 'peon-web-identity-check-' + str(os.getpid())
        def tmux(*args):
            return subprocess.run(['tmux', '-L', socket, *args], capture_output=True, text=True, check=True, timeout=5).stdout
        try:
            results = []
            for name in ('old', 'new'):
                tmux('-f', '/dev/null', 'new-session', '-d', '-s', name, 'sleep 60')
                tmux('set-option', '-t', name, '@peon_code', '1')
                tmux('set-option', '-p', '-t', name, '@peon_name', 'agent')
                with patch.object(bridge, 'tmux', side_effect=tmux):
                    pane = bridge.panes()[0]
                    self.assertRegex(pane['identity'], r'^\d+:\$\d+:\d+$')
                    self.assertEqual(bridge.panes()[0]['identity'], pane['identity'])
                    results.append(pane)
                    if name == 'new':
                        self.assertIsNone(bridge.snapshot(results[0]))
                        self.assertNotIn('output', results[0])
                tmux('kill-session', '-t', '=' + name)
            self.assertEqual(results[0]['id'], results[1]['id'])
            self.assertNotEqual(results[0]['identity'], results[1]['identity'])
        finally:
            for name in ('old', 'new'):
                subprocess.run(['tmux', '-L', socket, 'kill-session', '-t', '=' + name], capture_output=True)


if __name__ == '__main__':
    unittest.main()
