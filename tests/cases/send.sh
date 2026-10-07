#!/usr/bin/env bash
set -euo pipefail
CASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/helpers.sh
. "$CASE_DIR/../helpers.sh"

SEND_LOG="$TEST_DIR/tmux-send.log"

reset_send_log() {
  : >"$SEND_LOG"
  rm -f "$SEND_LOG.reads"
}

# How many times send read the target's box.
send_captures() {
  grep -c '^capture-pane' "$SEND_LOG" || true
}

# One refused send. Arguments after the wanted message are the FAKE_ settings
# that put the pane in the state under test.
assert_send_refused() {
  local what=$1 want=$2 out="$TEST_DIR/send-refuse.out" err="$TEST_DIR/send-refuse.err"
  shift 2
  reset_send_log
  if PATH="$SEND_BIN:$PATH" FAKE_TMUX_LOG="$SEND_LOG" \
    env "$@" "$ROOT/peon-code.sh" send %2 'hello world' >"$out" 2>"$err"; then
    fail "send pasted into $what"
  fi
  assert_contains "$err" "$want"
  assert_not_contains "$SEND_LOG" "paste-buffer"
  assert_not_contains "$SEND_LOG" "send-keys"
}

# Every state that must stop a send before anything is pasted.
test_send_refuses() {
  local empty_box busy_box menu_box codex_menu_box bare_box
  empty_box='output line
❯
────'
  busy_box='output line
❯ busy text
────'
  # A menu draws the marker on its selected row with the cursor right after
  # it, so the box measures empty and only the menu itself gives it away.
  menu_box='Do you trust this folder?
❯ 1. Yes, I trust this folder
  2. No, exit'
  codex_menu_box='Do you trust the contents of this directory?
› 1. Yes, continue
  2. No, quit'
  bare_box='some other CLI
> ready
────'

  assert_send_refused "a box that already had typed text" "target box busy after 10 tries, giving up" \
    FAKE_BOX="$busy_box" FAKE_CURSOR='11 1'
  # A box that stays busy is read once per try, so ten reads show send
  # retried to its cap before giving up.
  [ "$(send_captures)" = 10 ] || fail "send made $(send_captures) box reads, expected 10"
  assert_send_refused "a Japanese draft" "target box busy after 10 tries, giving up" \
    FAKE_BOX='────
❯ 日本語
────' FAKE_CURSOR='2 1'
  # The user typed, then moved the cursor back to the start of the line: the
  # text sits after the cursor, and the box is busy all the same.
  assert_send_refused "a box holding text the cursor had moved back over" "target box busy after 10 tries, giving up" \
    FAKE_BOX="$busy_box" FAKE_CURSOR='2 1'
  # In copy mode a paste lands but Enter goes to the copy-mode key table.
  assert_send_refused "a pane in copy mode" "is in copy mode after 10 tries, giving up" \
    FAKE_BOX="$empty_box" FAKE_CURSOR='2 1' FAKE_IN_MODE=1
  assert_send_refused "a pane sitting on a menu" "is on a dialog or a menu after 10 tries, giving up" \
    FAKE_BOX="$menu_box" FAKE_CURSOR='1 1'
  assert_send_refused "a codex pane sitting on a menu" "is on a dialog or a menu after 10 tries, giving up" \
    FAKE_BOX="$codex_menu_box" FAKE_CURSOR='1 1'
  # No marker means no box peon-code can measure, which no waiting fixes, so
  # send dies on the first read and says it cannot message the pane.
  assert_send_refused "a pane drawing no prompt marker" "draws no prompt marker peon-code knows" \
    FAKE_BOX="$bare_box" FAKE_CURSOR='7 1'
  [ "$(send_captures)" = 1 ] || fail "send made $(send_captures) box reads, expected 1"
  assert_send_refused "a pane back at a shell" "back at a shell" \
    FAKE_BOX="$empty_box" FAKE_CURSOR='2 1' FAKE_CMD=zsh
  # Without the launch-time pane option, send would reach any pane on the
  # tmux server, agent pane or not.
  assert_send_refused "a pane peon-code did not launch" "is not a peon-code agent pane" \
    FAKE_BOX="$empty_box" FAKE_CURSOR='2 1' FAKE_PEON_NAME=
}

# What send does once it has pasted: it polls the box and presses Enter only
# for a box holding exactly the message.
test_send_delivers() {
  local empty_box sent_box extra_box payload keys
  empty_box='output line
❯
────'
  sent_box='output line
❯ hello world
────'
  extra_box='output line
❯ hello worldXY
────'

  # The box holds the pasted message only from the fourth poll on, so a send
  # that stopped polling early would never see it.
  reset_send_log
  PATH="$SEND_BIN:$PATH" FAKE_TMUX_LOG="$SEND_LOG" FAKE_SETTLE=3 \
    FAKE_BOX="$empty_box" FAKE_CURSOR='2 1' \
    FAKE_BOX_AFTER="$sent_box" FAKE_CURSOR_AFTER='13 1' \
    "$ROOT/peon-code.sh" send %2 'hello world' >"$TEST_DIR/send-ok.out"
  assert_contains "$TEST_DIR/send-ok.out" "sent to %2"
  assert_contains "$SEND_LOG" "buffer-content:hello world"
  grep -Eq 'paste-buffer -b peon-code-[0-9]+-2 -dpt %2' "$SEND_LOG" ||
    fail "send did not paste through a unique tmux buffer"
  assert_contains "$SEND_LOG" "send-keys -t %2 Enter"
  [ "$(send_captures)" = 5 ] || fail "send made $(send_captures) box reads, expected 5"

  # A box holding more than the message never matches, so send polls to its
  # cap, leaves the box alone, and says so.
  reset_send_log
  if PATH="$SEND_BIN:$PATH" FAKE_TMUX_LOG="$SEND_LOG" \
    FAKE_BOX="$empty_box" FAKE_CURSOR='2 1' \
    FAKE_BOX_AFTER="$extra_box" FAKE_CURSOR_AFTER='15 1' \
    "$ROOT/peon-code.sh" send %2 'hello world' >"$TEST_DIR/send-extra.out" 2>"$TEST_DIR/send-extra.err"; then
    fail "send submitted a box holding more than the message"
  fi
  assert_contains "$TEST_DIR/send-extra.err" "no Enter sent"
  assert_contains "$SEND_LOG" "paste-buffer"
  assert_not_contains "$SEND_LOG" "send-keys"
  [ "$(send_captures)" = 11 ] || fail "send made $(send_captures) box reads, expected 11"

  # A paste tmux refused leaves the pane untouched, so the run says nothing
  # was sent instead of stopping without a word.
  reset_send_log
  if PATH="$SEND_BIN:$PATH" FAKE_TMUX_LOG="$SEND_LOG" FAKE_PASTE_FAIL=%2 \
    FAKE_BOX="$empty_box" FAKE_CURSOR='2 1' \
    "$ROOT/peon-code.sh" send %2 'hello world' \
    >"$TEST_DIR/send-refused.out" 2>"$TEST_DIR/send-refused.err"; then
    fail "send reported success after tmux refused the paste"
  fi
  assert_contains "$TEST_DIR/send-refused.err" "no message sent: tmux refused the paste"
  assert_not_contains "$SEND_LOG" "send-keys"

  # A CLI that collapses a multi-line paste into a placeholder row still gets
  # the Enter: the box was empty before the paste, so one placeholder is the
  # message. One form per supported CLI.
  local placeholder
  for placeholder in '[Pasted text #2 +15 lines]' '[Pasted Content 1234 chars]' '[Paste #2 - 15 lines]' '[Pasted: 5 lines]'; do
    reset_send_log
    PATH="$SEND_BIN:$PATH" FAKE_TMUX_LOG="$SEND_LOG" \
      FAKE_BOX="$empty_box" FAKE_CURSOR='2 1' \
      FAKE_BOX_AFTER="output line
❯ $placeholder
────" FAKE_CURSOR_AFTER='28 1' \
      "$ROOT/peon-code.sh" send %2 - >"$TEST_DIR/send-collapsed.out" <<'PEON'
line one
line two
PEON
    assert_contains "$TEST_DIR/send-collapsed.out" "sent to %2"
    assert_contains "$SEND_LOG" "send-keys -t %2 Enter"
  done

  # codex draws › as its prompt marker; its box reads and delivers all the
  # same, whether the paste shows literally or as its collapsed placeholder.
  reset_send_log
  PATH="$SEND_BIN:$PATH" FAKE_TMUX_LOG="$SEND_LOG" \
    FAKE_BOX='output line
›
────' FAKE_CURSOR='2 1' \
    FAKE_BOX_AFTER='output line
› hello world
────' FAKE_CURSOR_AFTER='13 1' \
    "$ROOT/peon-code.sh" send %2 'hello world' >"$TEST_DIR/send-codex.out"
  assert_contains "$TEST_DIR/send-codex.out" "sent to %2"
  assert_contains "$SEND_LOG" "send-keys -t %2 Enter"

  # A wrapped row can split a path token inside the pasted message.
  local msg wrapped_tail
  msg='run the check cd /home/user/project && bash tests/test_peon_code.sh and report the real output of the run back to me with each step checked'
  [ "${#msg}" -ge 120 ] || fail "wrapped-token message is shorter than 120 characters"
  wrapped_tail=${msg#*tests/}
  reset_send_log
  PATH="$SEND_BIN:$PATH" FAKE_TMUX_LOG="$SEND_LOG" \
    FAKE_BOX='output line
›
────' FAKE_CURSOR='2 1' \
    FAKE_BOX_AFTER="output line
› run the check cd /home/user/project && bash tests/
$wrapped_tail
────" FAKE_CURSOR_AFTER="${#wrapped_tail} 2" \
    "$ROOT/peon-code.sh" send %2 "$msg" >"$TEST_DIR/send-wrapped-token.out"
  assert_contains "$TEST_DIR/send-wrapped-token.out" "sent to %2"
  assert_contains "$SEND_LOG" "send-keys -t %2 Enter"

  # A placeholder with trailing typed text is not the message alone.
  reset_send_log
  if PATH="$SEND_BIN:$PATH" FAKE_TMUX_LOG="$SEND_LOG" \
    FAKE_BOX="$empty_box" FAKE_CURSOR='2 1' \
    FAKE_BOX_AFTER='output line
❯ [Pasted text #2 +15 lines] and more
────' FAKE_CURSOR_AFTER='37 1' \
    "$ROOT/peon-code.sh" send %2 'hello world' >/dev/null 2>"$TEST_DIR/send-collapsed-extra.err"; then
    fail "send submitted a placeholder box holding extra text"
  fi
  assert_contains "$TEST_DIR/send-collapsed-extra.err" "no Enter sent"
  assert_not_contains "$SEND_LOG" "send-keys"

  # A pane that enters copy mode after the paste keeps the message: Enter
  # would go to the copy-mode key table instead of the agent.
  reset_send_log
  if PATH="$SEND_BIN:$PATH" FAKE_TMUX_LOG="$SEND_LOG" FAKE_IN_MODE_AFTER=1 \
    FAKE_BOX="$empty_box" FAKE_CURSOR='2 1' \
    FAKE_BOX_AFTER="$sent_box" FAKE_CURSOR_AFTER='13 1' \
    "$ROOT/peon-code.sh" send %2 'hello world' >"$TEST_DIR/send-mode.out" 2>"$TEST_DIR/send-mode.err"; then
    fail "send pressed Enter on a pane in copy mode"
  fi
  assert_contains "$TEST_DIR/send-mode.err" "went into copy mode"
  assert_contains "$SEND_LOG" "paste-buffer"
  assert_not_contains "$SEND_LOG" "send-keys"

  # A bracketed-paste terminator in the message would end the paste early and
  # hand the rest to the receiving agent as keystrokes; it never gets pasted.
  reset_send_log
  payload=$(printf 'hello \033[201~\rrm -rf /tmp/peon-x')
  PATH="$SEND_BIN:$PATH" FAKE_TMUX_LOG="$SEND_LOG" \
    FAKE_BOX="$empty_box" FAKE_CURSOR='2 1' \
    FAKE_BOX_AFTER='output line
❯ hello [201~rm -rf /tmp/peon-x
────' FAKE_CURSOR_AFTER='31 1' \
    "$ROOT/peon-code.sh" send %2 "$payload" >"$TEST_DIR/send-esc.out"
  assert_contains "$TEST_DIR/send-esc.out" "sent to %2"
  assert_contains "$SEND_LOG" "buffer-content:hello [201~rm -rf /tmp/peon-x"
  if grep -Fq "$(printf '\033')" "$SEND_LOG"; then
    fail "send pasted an escape character into the pane"
  fi
  keys=$(grep -c '^send-keys' "$SEND_LOG" || true)
  [ "$keys" = 1 ] || fail "send made $keys send-keys calls, expected only the Enter"

  # A message of - comes in on stdin, so quoting it is the shell's problem,
  # not the sending agent's.
  reset_send_log
  PATH="$SEND_BIN:$PATH" FAKE_TMUX_LOG="$SEND_LOG" \
    FAKE_BOX="$empty_box" FAKE_CURSOR='2 1' \
    FAKE_BOX_AFTER="output line
❯ it is the user's box
────" FAKE_CURSOR_AFTER='21 1' \
    "$ROOT/peon-code.sh" send %2 - >"$TEST_DIR/send-stdin.out" <<'PEON'
it is the user's box
PEON
  assert_contains "$TEST_DIR/send-stdin.out" "sent to %2"
  assert_contains "$SEND_LOG" "buffer-content:it is the user's box"
  assert_contains "$SEND_LOG" "send-keys -t %2 Enter"
}

# msg presses Enter into a pane only once that pane's box shows the message,
# and one pane that never shows it does not hold up the others.

fake_bin=$(make_fake_commands)
SEND_BIN=$(make_send_bin "$fake_bin")
test_send_refuses
# Horizontal TUI borders lie outside the prompt-to-cursor rows. They must
# remain compatible with an empty prompt and with non-ASCII message delivery.
reset_send_log
PATH="$SEND_BIN:$PATH" FAKE_TMUX_LOG="$SEND_LOG" \
  FAKE_BOX='────
❯
────' FAKE_CURSOR='2 1' \
  FAKE_BOX_AFTER='────
❯ 日本語 🙂
────' FAKE_CURSOR_AFTER='2 1' \
  "$ROOT/peon-code.sh" send %2 '日本語 🙂' >"$TEST_DIR/send-unicode.out"
assert_contains "$SEND_LOG" 'buffer-content:日本語 🙂'
assert_contains "$SEND_LOG" 'send-keys -t %2 Enter'
test_send_delivers
echo "send: PASS"
