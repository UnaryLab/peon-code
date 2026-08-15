#!/usr/bin/env bash
set -euo pipefail
CASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/helpers.sh
. "$CASE_DIR/../helpers.sh"

# clear pastes the /clear slash command with nothing around it, and only into a
# pane whose input box is empty, then puts the brief back.
test_clear() {
  local fake_bin=$1 log="$TEST_DIR/tmux-clear.log" bin_dir="$TEST_DIR/clear-bin"
  local empty_box busy_box brief="$TEST_DIR/clear-brief.md"
  local enter_line brief_line
  write_slash_fake_tmux "$bin_dir" "$fake_bin"
  empty_box='output line
❯
────'
  busy_box='output line
❯ half a question
────'
  printf 'You are impl, follow the rules.\n' >"$brief"

  : >"$log"
  PATH="$bin_dir:$PATH" FAKE_TMUX_LOG="$log" FAKE_BOX="$empty_box" \
    FAKE_TMUX_BRIEF="$brief" \
    "$ROOT/peon-code.sh" clear all owned >"$TEST_DIR/clear.out"
  grep -Fqx -- 'buffer-content:/clear' "$log" ||
    fail "clear pasted something other than /clear alone"
  assert_not_contains "$log" "buffer-content:/compact"
  assert_contains "$log" "send-keys -t %1 Enter"
  assert_contains "$TEST_DIR/clear.out" "sent /clear to 1 pane(s) in session owned"
  # A cleared conversation has no brief left, so the brief goes back in once
  # the pane has settled.
  assert_contains "$log" "buffer-content:You are impl, follow the rules."
  enter_line=$(grep -n -Fx -- 'send-keys -t %1 Enter' "$log" | head -1 | cut -d: -f1)
  brief_line=$(grep -n -F -- 'buffer-content:You are impl' "$log" | head -1 | cut -d: -f1)
  if [ -z "$enter_line" ] || [ "$brief_line" -le "$enter_line" ]; then
    fail "clear pasted the brief before submitting /clear"
  fi
  # One Enter submits /clear, the second submits the brief the pane shows.
  [ "$(grep -c -Fx -- 'send-keys -t %1 Enter' "$log")" = 2 ] ||
    fail "clear left the brief in the box instead of submitting it"

  : >"$log"
  if PATH="$bin_dir:$PATH" FAKE_TMUX_LOG="$log" FAKE_BOX="$busy_box" \
    "$ROOT/peon-code.sh" clear >"$TEST_DIR/clear-busy.out" 2>"$TEST_DIR/clear-busy.err"; then
    fail "clear pasted into a box holding typed text"
  fi
  assert_contains "$TEST_DIR/clear-busy.err" "its input box holds typed text"
  assert_not_contains "$log" "paste-buffer"
  assert_not_contains "$log" "send-keys"

  : >"$log"
  if PATH="$bin_dir:$PATH" FAKE_TMUX_LOG="$log" FAKE_BOX="$empty_box" \
    "$ROOT/peon-code.sh" clear nobody owned >"$TEST_DIR/clear-name.out" 2>"$TEST_DIR/clear-name.err"; then
    fail "clear accepted an unknown pane name"
  fi
  assert_contains "$TEST_DIR/clear-name.err" "no pane named nobody in session owned"
  assert_not_contains "$log" "paste-buffer"

  # A pane that keeps redrawing after /clear never settles, so its brief is
  # held back rather than pasted over whatever is on screen.
  : >"$log"
  PATH="$bin_dir:$PATH" FAKE_TMUX_LOG="$log" FAKE_BOX="$empty_box" \
    FAKE_TMUX_BRIEF="$brief" FAKE_UNSETTLED=1 \
    "$ROOT/peon-code.sh" clear all owned \
    >"$TEST_DIR/clear-busy-after.out" 2>"$TEST_DIR/clear-busy-after.err"
  assert_contains "$TEST_DIR/clear-busy-after.out" "sent /clear to 1 pane(s) in session owned"
  assert_contains "$TEST_DIR/clear-busy-after.err" "no brief sent to impl %1: it is still busy after /clear"
  assert_not_contains "$log" "buffer-content:You are impl"
}

# compact and clear send to no pane at all when the calling pane is among
# the targets: sending to the others while the caller keeps its old context
# would leave the session out of sync.
test_slash_skips_all_when_caller_targeted() {
  local fake_bin=$1 log="$TEST_DIR/tmux-slash-self.log" bin_dir="$TEST_DIR/slash-self-bin"
  local empty_box brief="$TEST_DIR/slash-self-brief.md"
  write_slash_fake_tmux "$bin_dir" "$fake_bin"
  empty_box='output line
❯
────'
  printf 'You are impl, follow the rules.\n' >"$brief"

  # Two panes, one of them the caller: neither pane gets anything, and the
  # run still exits 0 with a warning on stderr.
  : >"$log"
  PATH="$bin_dir:$PATH" FAKE_TMUX_LOG="$log" FAKE_BOX="$empty_box" \
    FAKE_BOX2="$empty_box" FAKE_TMUX_BRIEF="$brief" \
    FAKE_PANES='%1 node impl
%2 node boss' \
    TMUX_PANE=%1 \
    "$ROOT/peon-code.sh" compact all owned \
    >"$TEST_DIR/slash-self.out" 2>"$TEST_DIR/slash-self.err" ||
    fail "compact exited nonzero when the calling pane was a target"
  assert_contains "$TEST_DIR/slash-self.err" \
    "not sending /compact: the calling pane is a target; run this command from a shell or another pane instead"
  assert_not_contains "$TEST_DIR/slash-self.out" "sent /compact"
  assert_not_contains "$log" "paste-buffer"
  assert_not_contains "$log" "load-buffer"
  assert_not_contains "$log" "send-keys -t %1"
  assert_not_contains "$log" "send-keys -t %2"

  # A single pane that is also the caller: same all-or-nothing skip.
  : >"$log"
  PATH="$bin_dir:$PATH" FAKE_TMUX_LOG="$log" FAKE_BOX="$empty_box" \
    FAKE_TMUX_BRIEF="$brief" TMUX_PANE=%1 \
    "$ROOT/peon-code.sh" clear all owned \
    >"$TEST_DIR/slash-self-only.out" 2>"$TEST_DIR/slash-self-only.err" ||
    fail "clear exited nonzero when the only match was the calling pane"
  assert_contains "$TEST_DIR/slash-self-only.err" \
    "not sending /clear: the calling pane is a target; run this command from a shell or another pane instead"
  assert_not_contains "$log" "paste-buffer"
  assert_not_contains "$log" "load-buffer"
}

fake_bin=$(make_fake_commands)
test_clear "$fake_bin"
test_slash_skips_all_when_caller_targeted "$fake_bin"
echo "clear: PASS"
