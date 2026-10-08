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
        with patch.object(bridge, 'tmux', side_effect=['\x1b[38;2;1;2;3mtext\x1b[0m', '› 2. Continue\n', '\x1b[31m› 2. Continue\x1b[0m\n', 'fg=#abcdef,bg=#123456\n', '0', '100:$1:202\t1500\t0\n']) as tmux:
            bridge.snapshot(pane, 2000)
        self.assertIn('-e', tmux.call_args_list[0].args)
        self.assertEqual(tmux.call_args_list[0].args[-2:], ('-S', '-2000'))
        self.assertEqual(pane['history'], 1500)
        self.assertEqual(pane['cursorY'], 0)
        self.assertTrue(pane['menu'])
        self.assertEqual(pane['screen'], '› 2. Continue\n')
        self.assertEqual(tmux.call_count, 6)
        self.assertEqual(tmux.call_args_list[1].args, ('capture-pane', '-p', '-t', '%2'))
        self.assertEqual(tmux.call_args_list[2].args, ('capture-pane', '-p', '-e', '-N', '-t', '%2'))
        self.assertEqual(pane['styledScreen'], '\x1b[31m› 2. Continue\x1b[0m\n')
        self.assertEqual(tmux.call_args_list[-1].args[-1], '#{pid}:#{session_id}:#{pane_pid}\t#{history_size}\t#{cursor_y}')
        self.assertEqual(pane['defaultStyle'], 'fg=#abcdef,bg=#123456')
        self.assertIn('\x1b[', pane['output'])

    def test_menu_uses_visible_screen_and_exact_patterns(self):
        history = '\x1b[31mEnter to confirm\x1b[0m\n❯ 1. Old choice\nReady\n\n'
        for screen, cursor_y, expected in (
                ('Ready\n\n', 0, False), ('\n\n', 1, False),
                ('Enter to confirm\n\n', 0, False), ('❯ 1. Accept\n', 0, True), ('› 0. Choice\n', 0, True),
                ('❯ 10. Choice\n', 0, False), ('enter to confirm\n', 0, False), ('> 1. Choice\n', 0, False),
                ('Quoted Enter to confirm\n❯ \n\n', 1, False),
                ('Quoted › 1. Choice\n❯ \n\n', 1, False),
                ('› quoted › 1. Old choice\n', 0, False),
                (' ❯ see ❯ 1. Old choice\n', 0, False),
                ('› first line\nquoted › 1. Old choice\ntail\n', 2, False),
                ('› please press Enter to confirm\n', 0, False),
                ('› first line\ncontinuation\nplease press Enter to confirm\n', 2, False),
                ('  ❯ 1. Accept\n', 0, True),
                ('❯ \nQuoted › 1. Choice\n', 0, False),
                ('Enter to confirm\n' + 'Ready\n' * 12, 12, False),
                ('Ready\n' * 12 + 'Enter to confirm\n\n', 11, True),
                ('❯ \n\n\nEnter to confirm\n', 0, True),
                ('❯ \n\n\n\nEnter to confirm\n', 0, False),
                ('❯ 3. Type something.\n  4. Chat about this\n', 0, True),
                ('Choose a model\n› 1. Model A\n  2. Model B\n\nenter select / esc back\n', 4, True),
                ('❯ \n', -1, False), ('❯ \n', 99, False), ('❯ \n', '', False), ('❯ \n', 'invalid', False)):
            pane = dict(id='%2', identity='100:$1:202')
            with self.subTest(screen=screen, cursor_y=cursor_y), patch.object(bridge, 'tmux', side_effect=[history, screen, screen, '', '0', f'100:$1:202\t2000\t{cursor_y}\n']):
                result = bridge.snapshot(pane, 200000)
            self.assertEqual(result['menu'], expected)
            self.assertEqual(result['output'], history)
            self.assertEqual(result['screen'], screen)
            self.assertEqual(result['history'], 2000)
            self.assertEqual(result['cursorY'], cursor_y if isinstance(cursor_y, int) else -1)

    def test_menu_uses_only_the_current_choice_block(self):
        for screen, cy, expected in (
                ('› Yes, proceed (y)\n  Yes, allow this command (a)\n  No, stop (n)\n\nEnter to select\n', 4, True),
                ('  Yes, proceed (y)\n  › Yes, allow this command (a)\n  No, stop (n)\n', 1, True),
                ('  Yes, proceed (y)\n  Yes, allow this command (a)\n› No, stop (n)\n', 2, True),
                ('› Yes, proceed (y)\t \n\n  No, stop (n)\n', 0, False),
                ('› fix item (a)\n', 0, False),
                ('› fix item (y)\n', 0, False),
                ('› fix item (n)\n', 0, False),
                ('› Yes, proceed (y)\n  Another action (b)\n', 1, True),
                ('› Another action (b)\n', 0, False),
                ('› Yes, proceed (y)\n  No, stop (n)\n› \n', 2, False),
                ('› quote › Yes, proceed (y)\n', 0, False),
                ('› first line\nquoted › Yes, proceed (y)\ntail\n', 2, False),
                ('  Yes, proceed (y)\n  No, stop (n)\n', 1, False),
                ('› Yes, proceed (y)\n', -1, False),
                ('› Yes, proceed (y)\n', 99, False)):
            with self.subTest(screen=screen, cy=cy):
                pane = dict(id='%2', identity='100:$1:202')
                with patch.object(bridge, 'tmux', side_effect=['history', screen, screen, '', '0', f'100:$1:202\t0\t{cy}\n']) as tmux:
                    self.assertEqual(bridge.snapshot(pane)['menu'], expected)
                self.assertEqual(tmux.call_count, 6)

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
