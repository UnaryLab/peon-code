#!/usr/bin/env bash
set -euo pipefail
CASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/helpers.sh
. "$CASE_DIR/../helpers.sh"

# compact pastes the /compact slash command with nothing around it, and only
# into a pane whose input box is empty.
test_compact() {
  local fake_bin=$1 log="$TEST_DIR/tmux-compact.log" bin_dir="$TEST_DIR/compact-bin"
  local empty_box busy_box menu_box brief="$TEST_DIR/compact-brief.md"
  local enter_line brief_line settle_reads working_row quoted_row
  write_slash_fake_tmux "$bin_dir" "$fake_bin"
  empty_box='output line
❯
────'
  busy_box='output line
❯ half a question
────'
  menu_box='Do you trust this folder?
❯ 1. Yes, I trust this folder
  2. No, exit'
  printf 'You are impl, follow the rules.\n' >"$brief"

  : >"$log"
  PATH="$bin_dir:$PATH" FAKE_TMUX_LOG="$log" FAKE_BOX="$empty_box" \
    FAKE_TMUX_BRIEF="$brief" \
    "$ROOT/peon-code.sh" compact all owned >"$TEST_DIR/compact.out"
  # No [from user] prefix and nothing else: a prefix stops the CLI from
  # reading the line as a slash command.
  grep -Fqx -- 'buffer-content:/compact' "$log" ||
    fail "compact pasted something other than /compact alone"
  assert_contains "$log" "send-keys -t %1 Enter"
  assert_contains "$TEST_DIR/compact.out" "sent /compact to 1 pane(s) in session owned"
  # The brief goes back in once the pane has settled, so the agent gets its
  # standing instructions after the compaction dropped them.
  assert_contains "$log" "buffer-content:You are impl, follow the rules."
  enter_line=$(grep -n -Fx -- 'send-keys -t %1 Enter' "$log" | head -1 | cut -d: -f1)
  brief_line=$(grep -n -F -- 'buffer-content:You are impl' "$log" | head -1 | cut -d: -f1)
  if [ -z "$enter_line" ] || [ "$brief_line" -le "$enter_line" ]; then
    fail "compact pasted the brief before submitting /compact"
  fi
  settle_reads=$(awk -v a="$enter_line" -v b="$brief_line" \
    'NR > a && NR < b && /^capture-pane/ { n++ } END { print n + 0 }' "$log")
  [ "$settle_reads" -ge 2 ] ||
    fail "compact made $settle_reads box reads between /compact and the brief, expected a settle wait"
  # One Enter submits /compact, the second submits the brief the pane shows.
  [ "$(grep -c -Fx -- 'send-keys -t %1 Enter' "$log")" = 2 ] ||
    fail "compact left the brief in the box instead of submitting it"

  : >"$log"
  if PATH="$bin_dir:$PATH" FAKE_TMUX_LOG="$log" FAKE_BOX="$busy_box" \
    "$ROOT/peon-code.sh" compact >"$TEST_DIR/compact-busy.out" 2>"$TEST_DIR/compact-busy.err"; then
    fail "compact pasted into a box holding typed text"
  fi
  assert_contains "$TEST_DIR/compact-busy.err" "its input box holds typed text"
  assert_not_contains "$TEST_DIR/compact-busy.err" "no Enter sent"
  assert_not_contains "$log" "paste-buffer"
  assert_not_contains "$log" "send-keys"

  for working_row in '✽ Fermenting… (48s · ↓ 1.9k tokens · thought for 8s)' \
    '• Working (12s • esc to interrupt)' \
    '  • Waiting for background terminal (5m 12s • esc to interrupt)'; do
    : >"$log"
    if PATH="$bin_dir:$PATH" FAKE_TMUX_LOG="$log" FAKE_BOX="$working_row

────
❯
────" "$ROOT/peon-code.sh" compact all owned >"$TEST_DIR/compact-turn.out" 2>"$TEST_DIR/compact-turn.err"; then
      fail "compact queued a command during a working turn"
    fi
    assert_contains "$TEST_DIR/compact-turn.err" "skipped %1: it is busy with a turn"
    assert_not_contains "$TEST_DIR/compact-turn.err" "no Enter sent"
    assert_not_contains "$log" "paste-buffer"
    assert_not_contains "$log" "send-keys"
  done

  for quoted_row in 'Output quotes "✽ Fermenting… (48s · ↓ 1.9k tokens · thought for 8s)" and "• Working (12s • esc to interrupt)".' \
    '● I checked the new busy check and Claude draws its working row as ✽ Fermenting… (48s · ↓ 1.9k tokens)'; do
    : >"$log"
    PATH="$bin_dir:$PATH" FAKE_TMUX_LOG="$log" FAKE_BOX="$quoted_row
❯
────" FAKE_TMUX_BRIEF="$brief" "$ROOT/peon-code.sh" compact all owned \
      >"$TEST_DIR/compact-quoted.out" 2>"$TEST_DIR/compact-quoted.err"
    assert_contains "$log" "buffer-content:/compact"
    assert_contains "$log" "buffer-content:You are impl, follow the rules."
    assert_not_contains "$TEST_DIR/compact-quoted.err" "busy with a turn"
  done

  : >"$log"
  if PATH="$bin_dir:$PATH" FAKE_TMUX_LOG="$log" FAKE_BOX="$empty_box" \
    "$ROOT/peon-code.sh" compact nobody owned >"$TEST_DIR/compact-name.out" 2>"$TEST_DIR/compact-name.err"; then
    fail "compact accepted an unknown pane name"
  fi
  assert_contains "$TEST_DIR/compact-name.err" "no pane named nobody in session owned"
  assert_contains "$TEST_DIR/compact-name.err" "impl %1"
  assert_not_contains "$log" "paste-buffer"

  # Two panes, one free and one holding typed text: the free one is compacted
  # and the busy one is left as the user typed it.
  : >"$log"
  PATH="$bin_dir:$PATH" FAKE_TMUX_LOG="$log" FAKE_BOX="$empty_box" \
    FAKE_BOX2="$busy_box" FAKE_TMUX_BRIEF="$brief" \
    FAKE_PANES='%1 node impl
%2 node boss' \
    "$ROOT/peon-code.sh" compact all owned \
    >"$TEST_DIR/compact-partial.out" 2>"$TEST_DIR/compact-partial.err"
  assert_contains "$TEST_DIR/compact-partial.out" "sent /compact to 1 pane(s) in session owned"
  [ "$(grep -c -Fx -- 'buffer-content:/compact' "$log")" = 1 ] ||
    fail "compact pasted /compact more than once"
  assert_contains "$log" "send-keys -t %1 Enter"
  assert_not_contains "$log" "send-keys -t %2"
  assert_not_contains "$log" "-dpt %2"
  assert_contains "$TEST_DIR/compact-partial.err" "skipped %2: its input box holds typed text"
  # Only the compacted pane is rebriefed; the busy one is left as the user
  # typed it.
  [ "$(grep -c -F -- 'buffer-content:You are impl' "$log")" = 1 ] ||
    fail "compact pasted the brief into a pane it skipped"

  # Two panes, one taking the paste and one refusing it: the refusing pane is
  # reported and the run carries on through the rest.
  : >"$log"
  PATH="$bin_dir:$PATH" FAKE_TMUX_LOG="$log" FAKE_BOX="$empty_box" \
    FAKE_BOX2="$empty_box" FAKE_TMUX_BRIEF="$brief" FAKE_PASTE_FAIL=%2 \
    FAKE_PANES='%1 node impl
%2 node boss' \
    "$ROOT/peon-code.sh" compact all owned \
    >"$TEST_DIR/compact-refused.out" 2>"$TEST_DIR/compact-refused.err"
  assert_contains "$TEST_DIR/compact-refused.err" "skipped %2: tmux refused the paste"
  assert_not_contains "$TEST_DIR/compact-refused.err" "no Enter sent"
  assert_contains "$TEST_DIR/compact-refused.out" "sent /compact to 1 pane(s) in session owned"
  assert_contains "$log" "send-keys -t %1 Enter"
  assert_not_contains "$log" "send-keys -t %2"
  # The pane that took /compact still gets its brief back.
  [ "$(grep -c -F -- 'buffer-content:You are impl' "$log")" = 1 ] ||
    fail "compact stopped before rebriefing the pane that took /compact"

  # A pane that keeps redrawing after /compact never settles, so its brief is
  # held back rather than pasted over whatever is on screen.
  : >"$log"
  PATH="$bin_dir:$PATH" FAKE_TMUX_LOG="$log" FAKE_BOX="$empty_box" \
    FAKE_TMUX_BRIEF="$brief" FAKE_UNSETTLED=1 \
    "$ROOT/peon-code.sh" compact all owned \
    >"$TEST_DIR/compact-busy-after.out" 2>"$TEST_DIR/compact-busy-after.err"
  assert_contains "$TEST_DIR/compact-busy-after.out" "sent /compact to 1 pane(s) in session owned"
  assert_contains "$TEST_DIR/compact-busy-after.err" "no brief sent to impl %1: it is still busy after /compact"
  assert_contains "$log" "set -pt %1 @peon_rebrief_pending 1"
  assert_not_contains "$log" "buffer-content:You are impl"

  # A brief is held back from a box holding typed text, so text typed while a
  # pane compacted is left as the user typed it.
  : >"$log"
  if PATH="$bin_dir:$PATH" FAKE_TMUX_LOG="$log" FAKE_BOX="$busy_box" \
    FAKE_TMUX_BRIEF="$brief" \
    "$ROOT/peon-code.sh" rebrief all owned \
    >"$TEST_DIR/rebrief-typed.out" 2>"$TEST_DIR/rebrief-typed.err"; then
    fail "rebrief pasted into a box holding typed text"
  fi
  assert_contains "$TEST_DIR/rebrief-typed.err" "no brief sent to impl %1: its input box holds typed text"
  assert_not_contains "$log" "load-buffer"
  assert_not_contains "$log" "paste-buffer"
  assert_not_contains "$log" "send-keys"

  # A pane sitting on a menu measures an empty box, so only the menu itself
  # keeps the brief out; the Enter after a paste would answer the menu.
  : >"$log"
  if PATH="$bin_dir:$PATH" FAKE_TMUX_LOG="$log" FAKE_BOX="$menu_box" \
    FAKE_TMUX_BRIEF="$brief" \
    "$ROOT/peon-code.sh" rebrief all owned \
    >"$TEST_DIR/rebrief-menu.out" 2>"$TEST_DIR/rebrief-menu.err"; then
    fail "rebrief pasted into a pane on a menu"
  fi
  assert_contains "$TEST_DIR/rebrief-menu.err" \
    "no brief sent to impl %1: its input box holds typed text, or it is on a dialog or a menu"
  assert_not_contains "$log" "load-buffer"
  assert_not_contains "$log" "paste-buffer"
  assert_not_contains "$log" "send-keys"

  mv "$bin_dir/tmux" "$bin_dir/tmux-base"
  cat >"$bin_dir/tmux" <<'FAKE_BUSY_TMUX'
#!/usr/bin/env bash
status=0
if [ "$1" = capture-pane ] && grep -Fqx 'send-keys -t %1 Enter' "$FAKE_TMUX_LOG"; then
  printf '• Working (24s • esc to interrupt)\n'
fi
"${0%/*}/tmux-base" "$@" || status=$?
exit "$status"
FAKE_BUSY_TMUX
  chmod +x "$bin_dir/tmux"
  : >"$log"
  PATH="$bin_dir:$PATH" FAKE_TMUX_LOG="$log" FAKE_BOX="$empty_box" FAKE_TMUX_BRIEF="$brief" \
    "$ROOT/peon-code.sh" compact all owned >"$TEST_DIR/compact-turn-after.out" 2>"$TEST_DIR/compact-turn-after.err"
  assert_contains "$log" "send-keys -t %1 Enter"
  assert_contains "$log" "set -pt %1 @peon_rebrief_pending 1"
  assert_contains "$TEST_DIR/compact-turn-after.err" "no brief sent to impl %1: it is still busy after /compact"
  assert_not_contains "$log" "buffer-content:You are impl"
}

test_busy_near_prompt() (
  # shellcheck source=lib/cli.sh
  . "$ROOT/lib/cli.sh"
  # shellcheck source=lib/tmux.sh
  . "$ROOT/lib/tmux.sh"
  local busy_test_screen busy_test_bin marker
  tmux() {
    case $1 in
      show-options) echo "$busy_test_bin" ;;
      capture-pane) printf '%s\n' "$busy_test_screen" ;;
    esac
  }
  for busy_test_bin in claude codex; do
    marker=$(cli_call "$busy_test_bin" prompt_marker)
    busy_test_screen="  ✽ Fermenting… (48s\") matches a loose regex, and this quote continues.
output row 1
output row 2
output row 3
output row 4

────
$marker"
    if pane_is_busy %1; then fail "$busy_test_bin treated a wrapped output quote as busy"; fi
    busy_test_screen="output row
✽ Fermenting… (48s · ↓ 1.9k tokens · thought for 8s)

────
$marker"
    pane_is_busy %1 || fail "$busy_test_bin missed its working row above the input box"
  done
)

fake_bin=$(make_fake_commands)
test_busy_near_prompt
test_compact "$fake_bin"
echo "compact: PASS"
