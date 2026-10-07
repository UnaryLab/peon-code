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
        with patch.object(bridge, 'tmux', side_effect=['\x1b[38;2;1;2;3mtext\x1b[0m', '› 2. Continue\n', 'fg=#abcdef,bg=#123456\n', '0', '100:$1:202\t1500\n']) as tmux:
            bridge.snapshot(pane, 2000)
        self.assertIn('-e', tmux.call_args_list[0].args)
        self.assertEqual(tmux.call_args_list[0].args[-2:], ('-S', '-2000'))
        self.assertEqual(pane['history'], 1500)
        self.assertTrue(pane['menu'])
        self.assertEqual(pane['screen'], '› 2. Continue\n')
        self.assertEqual(tmux.call_count, 5)
        self.assertEqual(tmux.call_args_list[1].args, ('capture-pane', '-p', '-t', '%2'))
        self.assertEqual(pane['defaultStyle'], 'fg=#abcdef,bg=#123456')
        self.assertIn('\x1b[', pane['output'])

    def test_menu_uses_visible_screen_and_exact_patterns(self):
        history = '\x1b[31mEnter to confirm\x1b[0m\n❯ 1. Old choice\nReady\n\n'
        for screen, expected in (
                ('Ready\n\n', False), ('\n\n', False),
                ('Enter to confirm\n\n', True), ('❯ 1. Accept\n', True), ('› 0. Choice\n', True),
                ('❯ 10. Choice\n', False), ('enter to confirm\n', False), ('> 1. Choice\n', False),
                ('Quoted Enter to confirm\n❯ \n\n', False),
                ('Enter to confirm\n' + 'Ready\n' * 12, False),
                ('Ready\n' * 12 + 'Enter to confirm\n\n', True),
                ('❯ 3. Type something.\n  4. Chat about this\n', True)):
            pane = dict(id='%2', identity='100:$1:202')
            with self.subTest(screen=screen), patch.object(bridge, 'tmux', side_effect=[history, screen, '', '0', '100:$1:202\t2000\n']):
                result = bridge.snapshot(pane, 200000)
            self.assertEqual(result['menu'], expected)
            self.assertEqual(result['output'], history)
            self.assertEqual(result['screen'], screen)
            self.assertEqual(result['history'], 2000)

    def test_real_tmux_inherited_background_and_truecolor(self):
        socket = 'peon-web-style-check-' + str(os.getpid())
        def tmux(*args):
            return subprocess.run(['tmux', '-L', socket, *args], capture_output=True, text=True, check=True, timeout=5).stdout
        try:
            tmux('-f', '/dev/null', 'new-session', '-d', '-s', 'style-check', '-x', '80', '-y', '4', "printf 'Enter to confirm\\n\\n\\n\\n\\n\\033[38;2;200;30;40mCOLOUR\\033[0m\\n'; sleep 5")
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
            self.assertFalse(result['menu'])
            screen = tmux('capture-pane', '-p', '-t', pane)
            self.assertIn('Enter to confirm', result['output'])
            self.assertNotIn('Enter to confirm', screen)
            self.assertEqual(result['screen'], screen)
            self.assertTrue(screen.endswith('\n\n'))
            with patch.object(bridge, 'tmux', side_effect=tmux):
                deeper = bridge.snapshot(dict(result), 2000)
            self.assertFalse(deeper['menu'])
            self.assertEqual(deeper['output'], result['output'])
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
