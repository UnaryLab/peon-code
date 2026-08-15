#!/usr/bin/env bash
set -euo pipefail
CASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/helpers.sh
. "$CASE_DIR/../helpers.sh"

# rebrief re-pastes the brief file stored in @peon_brief; a pane with no
# stored brief is skipped with a note, and sending none is an error.
test_rebrief() {
  local fake_bin=$1 log="$TEST_DIR/tmux-rebrief.log" home_dir="$TEST_DIR/home-rebrief"
  local paste_line enter_line
  local empty_box='output line
❯
────'
  local brief_box='output line
❯ You are boss, follow the rules.
────'
  local placeholder_box='output line
❯ [Pasted text #1 +15 lines]
────'
  mkdir -p "$home_dir"
  printf 'You are boss, follow the rules.\n' >"$TEST_DIR/rebrief-brief.md"

  : >"$log"
  PATH="$fake_bin:$PATH" HOME="$home_dir" FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=owned \
    FAKE_TMUX_BRIEF="$TEST_DIR/rebrief-brief.md" FAKE_TMUX_CAPTURE="$empty_box" \
    FAKE_TMUX_CAPTURE_AFTER="$brief_box" \
    "$ROOT/peon-code.sh" rebrief all owned >"$TEST_DIR/rebrief.out"
  assert_contains "$TEST_DIR/rebrief.out" "rebriefed 1 pane(s) in session owned"
  assert_contains "$log" "buffer-content:You are boss, follow the rules."
  # The Enter follows the paste, and only after a box read showed the brief.
  paste_line=$(grep -n -F -- "paste-buffer" "$log" | head -1 | cut -d: -f1)
  enter_line=$(grep -n -Fx -- "send-keys -t %1 Enter" "$log" | head -1 | cut -d: -f1)
  [ -n "$enter_line" ] || fail "rebrief pressed no Enter after the brief landed"
  [ "$enter_line" -gt "$paste_line" ] || fail "rebrief pressed Enter before pasting the brief"
  awk -v a="$paste_line" -v b="$enter_line" \
    'NR > a && NR < b && /^capture-pane/ { n++ } END { exit !(n + 0) }' "$log" ||
    fail "rebrief pressed Enter without reading the box after the paste"

  # A CLI that draws the brief as one paste placeholder row instead of its
  # text still gets its Enter.
  : >"$log"
  PATH="$fake_bin:$PATH" HOME="$home_dir" FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=owned \
    FAKE_TMUX_BRIEF="$TEST_DIR/rebrief-brief.md" FAKE_TMUX_CAPTURE="$empty_box" \
    FAKE_TMUX_CAPTURE_AFTER="$placeholder_box" \
    "$ROOT/peon-code.sh" rebrief all owned >"$TEST_DIR/rebrief-placeholder.out"
  assert_contains "$TEST_DIR/rebrief-placeholder.out" "rebriefed 1 pane(s) in session owned"
  assert_contains "$log" "send-keys -t %1 Enter"

  # A box that never shows the brief keeps the Enter back, so the pasted text
  # is left for the user to submit.
  : >"$log"
  if PATH="$fake_bin:$PATH" HOME="$home_dir" FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=owned \
    FAKE_TMUX_BRIEF="$TEST_DIR/rebrief-brief.md" FAKE_TMUX_CAPTURE="$empty_box" \
    "$ROOT/peon-code.sh" rebrief all owned >"$TEST_DIR/rebrief-unseen.out" 2>"$TEST_DIR/rebrief-unseen.err"; then
    fail "rebrief reported a brief its target never showed as sent"
  fi
  assert_contains "$TEST_DIR/rebrief-unseen.err" "no Enter sent to impl %1: the brief is in its box for the user to submit"
  assert_contains "$TEST_DIR/rebrief-unseen.err" "no brief sent in session owned"
  assert_contains "$log" "paste-buffer"
  assert_not_contains "$log" "send-keys"

  # An empty brief file paired with a dialog the paste opened: the dialog
  # measures the box empty, which must not count as the brief showing up.
  : >"$log"
  : >"$TEST_DIR/rebrief-empty.md"
  if PATH="$fake_bin:$PATH" HOME="$home_dir" FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=owned \
    FAKE_TMUX_BRIEF="$TEST_DIR/rebrief-empty.md" FAKE_TMUX_CAPTURE="$empty_box" \
    FAKE_TMUX_CAPTURE_AFTER='Do you trust this folder?
❯ 1. Yes, I trust this folder' \
    "$ROOT/peon-code.sh" rebrief all owned >"$TEST_DIR/rebrief-empty.out" 2>"$TEST_DIR/rebrief-empty.err"; then
    fail "rebrief answered a dialog with an empty brief"
  fi
  assert_not_contains "$log" "send-keys"

  # A pane in copy mode routes keys through the copy-mode table, so the Enter
  # is held back there too, even though the box shows the brief.
  : >"$log"
  if PATH="$fake_bin:$PATH" HOME="$home_dir" FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=owned \
    FAKE_TMUX_BRIEF="$TEST_DIR/rebrief-brief.md" FAKE_TMUX_CAPTURE="$empty_box" \
    FAKE_TMUX_CAPTURE_AFTER="$brief_box" FAKE_IN_MODE=1 \
    "$ROOT/peon-code.sh" rebrief all owned >"$TEST_DIR/rebrief-copy.out" 2>"$TEST_DIR/rebrief-copy.err"; then
    fail "rebrief pressed Enter on a pane in copy mode"
  fi
  assert_contains "$TEST_DIR/rebrief-copy.err" "no Enter sent to impl %1: the brief is in its box for the user to submit"
  assert_not_contains "$log" "send-keys"

  : >"$log"
  if PATH="$fake_bin:$PATH" HOME="$home_dir" FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=owned \
    "$ROOT/peon-code.sh" rebrief all owned >"$TEST_DIR/rebrief-none.out" 2>"$TEST_DIR/rebrief-none.err"; then
    fail "rebrief succeeded with no stored brief"
  fi
  assert_contains "$TEST_DIR/rebrief-none.err" "no stored brief for impl"

  : >"$log"
  if PATH="$fake_bin:$PATH" HOME="$home_dir" FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=owned \
    FAKE_TMUX_BRIEF="$TEST_DIR/rebrief-brief.md" FAKE_TMUX_CAPTURE="$empty_box" \
    FAKE_LOAD_BUFFER_EXIT=3 \
    "$ROOT/peon-code.sh" rebrief all owned >"$TEST_DIR/rebrief-fail.out" 2>"$TEST_DIR/rebrief-fail.err"; then
    fail "rebrief succeeded with a refused paste"
  fi
  assert_contains "$TEST_DIR/rebrief-fail.err" "no brief sent to impl %1: tmux refused the paste"
  assert_not_contains "$TEST_DIR/rebrief-fail.out" "rebriefed 1 pane(s)"
  assert_not_contains "$log" "paste-buffer"
  assert_not_contains "$log" "send-keys"

  : >"$log"
  if PATH="$fake_bin:$PATH" HOME="$home_dir" FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=owned \
    FAKE_TMUX_BRIEF="$TEST_DIR/rebrief-brief.md" FAKE_TMUX_CAPTURE='some other CLI
> ready' \
    "$ROOT/peon-code.sh" rebrief all owned >"$TEST_DIR/rebrief-bare.out" 2>"$TEST_DIR/rebrief-bare.err"; then
    fail "rebrief succeeded on a pane drawing no prompt marker"
  fi
  assert_contains "$TEST_DIR/rebrief-bare.err" "no brief sent to impl %1: it draws no prompt marker peon-code knows"
  assert_not_contains "$log" "load-buffer"
  assert_not_contains "$log" "paste-buffer"
}

fake_bin=$(make_fake_commands)
test_rebrief "$fake_bin"
echo "rebrief: PASS"
