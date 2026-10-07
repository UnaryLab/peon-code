#!/usr/bin/env bash
set -euo pipefail
CASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/helpers.sh
. "$CASE_DIR/../helpers.sh"

test_msg() {
  local fake_bin=$1 log="$TEST_DIR/tmux-msg.log" bin_dir="$TEST_DIR/msg-bin"
  local paste_line enter_line
  mkdir -p "$bin_dir"
  cp "$fake_bin/sleep" "$bin_dir/sleep"
  cat >"$bin_dir/tmux" <<'FAKE_TMUX'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = -V ]; then printf 'tmux 3.4\n'; exit 0; fi
printf '%s\n' "$*" >>"$FAKE_TMUX_LOG"
pane=%1
case "$*" in *%2*) pane=%2 ;; esac
# tmux refuses the paste for a pane named in FAKE_REFUSE.
case " ${FAKE_REFUSE:-} " in
  *" $pane "*) case ${1:-} in paste-buffer) exit 1 ;; esac ;;
esac
# A pane shows FAKE_TYPED in its box before any paste, as text the user typed.
box="output line
❯${FAKE_TYPED:+ $FAKE_TYPED}
────"
# A pane shows what was pasted into it once the paste has reached it, except a
# pane named in FAKE_BLIND, whose box never shows the paste.
case " ${FAKE_BLIND:-} " in
  *" $pane "*) ;;
  *)
    if grep -Fq -- "-dpt $pane" "$FAKE_TMUX_LOG"; then
      box="output line
❯ $(grep -F 'buffer-content:' "$FAKE_TMUX_LOG" | tail -1 | cut -d: -f2-)
────"
    fi
    ;;
esac
case ${1:-} in
  has-session) ;;
  show-options) printf '1\n' ;;
  list-panes) printf '%s\n' "${FAKE_PANES:-%1 node impl}" ;;
  display)
    case "$*" in
      *pane_in_mode*) printf '%s\n' "${FAKE_IN_MODE:-0}" ;;
      *cursor_y*) printf '1\n' ;;
    esac
    ;;
  capture-pane) printf '%s\n' "$box" ;;
  load-buffer) printf 'buffer-content:%s\n' "$(cat)" >>"$FAKE_TMUX_LOG" ;;
esac
exit 0
FAKE_TMUX
  chmod +x "$bin_dir/tmux"

  : >"$log"
  PATH="$bin_dir:$PATH" FAKE_TMUX_LOG="$log" \
    FAKE_PANES='%1 node impl
%2 node boss' \
    "$ROOT/peon-code.sh" msg all hello owned >"$TEST_DIR/msg-all.out" 2>"$TEST_DIR/msg-all.err"
  assert_contains "$TEST_DIR/msg-all.out" "sent to 2 pane(s) in session owned"
  assert_contains "$log" "buffer-content:[from user] hello"
  assert_contains "$log" "send-keys -t %2 Enter"
  # The Enter follows the paste, and only after a box read showed the message.
  paste_line=$(grep -n -F -- "-dpt %1" "$log" | head -1 | cut -d: -f1)
  enter_line=$(grep -n -Fx -- "send-keys -t %1 Enter" "$log" | head -1 | cut -d: -f1)
  [ -n "$enter_line" ] || fail "msg pressed no Enter after the message landed"
  [ "$enter_line" -gt "$paste_line" ] || fail "msg pressed Enter before pasting the message"
  awk -v a="$paste_line" -v b="$enter_line" \
    'NR > a && NR < b && /^capture-pane/ { n++ } END { exit !(n + 0) }' "$log" ||
    fail "msg pressed Enter without reading the box after the paste"

  # One pane whose box never shows the message: it keeps its Enter back and is
  # reported, and the other pane still gets its message submitted.
  : >"$log"
  if PATH="$bin_dir:$PATH" FAKE_TMUX_LOG="$log" FAKE_BLIND=%2 \
    FAKE_PANES='%1 node impl
%2 node boss' \
    "$ROOT/peon-code.sh" msg all hello owned \
    >"$TEST_DIR/msg-blind.out" 2>"$TEST_DIR/msg-blind.err"; then
    fail "msg reported a message its target never showed as delivered"
  fi
  assert_contains "$TEST_DIR/msg-blind.out" "sent to 1 pane(s) in session owned"
  assert_contains "$TEST_DIR/msg-blind.err" \
    "no Enter sent to boss %2: the message is in its box for you to submit"
  assert_contains "$TEST_DIR/msg-blind.err" "1 message(s) were not delivered in session owned"
  assert_contains "$log" "send-keys -t %1 Enter"
  assert_not_contains "$log" "send-keys -t %2"

  # A pane tmux refuses the paste for takes no message and is reported, and the
  # other pane still gets its own.
  : >"$log"
  if PATH="$bin_dir:$PATH" FAKE_TMUX_LOG="$log" FAKE_REFUSE=%2 \
    FAKE_PANES='%1 node impl
%2 node boss' \
    "$ROOT/peon-code.sh" msg all hello owned \
    >"$TEST_DIR/msg-refused.out" 2>"$TEST_DIR/msg-refused.err"; then
    fail "msg reported a message tmux refused as delivered"
  fi
  assert_contains "$TEST_DIR/msg-refused.out" "sent to 1 pane(s) in session owned"
  assert_contains "$TEST_DIR/msg-refused.err" \
    "no message sent to boss %2: tmux refused the paste"
  assert_contains "$log" "send-keys -t %1 Enter"
  assert_not_contains "$log" "send-keys -t %2"

  # A pane in copy mode routes an Enter through the copy-mode key table, so it
  # is skipped before any paste.
  : >"$log"
  if PATH="$bin_dir:$PATH" FAKE_TMUX_LOG="$log" FAKE_IN_MODE=1 \
    "$ROOT/peon-code.sh" msg all hello owned \
    >"$TEST_DIR/msg-copy.out" 2>"$TEST_DIR/msg-copy.err"; then
    fail "msg reported a message to a pane in copy mode as delivered"
  fi
  assert_contains "$TEST_DIR/msg-copy.out" "sent to 0 pane(s) in session owned"
  assert_contains "$TEST_DIR/msg-copy.err" "no message sent to impl %1: it is in copy mode"
  assert_contains "$TEST_DIR/msg-copy.err" "no message sent in session owned"
  assert_not_contains "$log" "paste-buffer"
  assert_not_contains "$log" "send-keys"

  # A pane whose box holds typed text is skipped before any paste, so a long
  # message cannot scroll the typed text out of view and submit it along with
  # the message.
  : >"$log"
  if PATH="$bin_dir:$PATH" FAKE_TMUX_LOG="$log" FAKE_TYPED='half a thought' \
    FAKE_PANES='%1 node impl' \
    "$ROOT/peon-code.sh" msg all hello owned \
    >"$TEST_DIR/msg-typed.out" 2>"$TEST_DIR/msg-typed.err"; then
    fail "msg reported a message to a box holding typed text as delivered"
  fi
  assert_contains "$TEST_DIR/msg-typed.err" \
    "no message sent to impl %1: its input box holds typed text"
  assert_not_contains "$log" "paste-buffer"
  assert_not_contains "$log" "send-keys"
}


fake_bin=$(make_fake_commands)
test_msg "$fake_bin"
echo "msg: PASS"
