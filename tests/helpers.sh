#!/usr/bin/env bash
# Shared test harness: sourced by each tests/cases/*.sh file, not run directly.
# ROOT and TEST_DIR are set only if a caller has not already set them, so
# re-sourcing is harmless.
: "${ROOT:=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
: "${TEST_DIR:=$(mktemp -d "${TMPDIR:-/tmp}/peon-code-test.XXXXXX")}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local file=$1 text=$2
  grep -Fq -- "$text" "$file" || fail "$file does not contain: $text"
}

assert_not_contains() {
  local file=$1 text=$2
  if grep -Fq -- "$text" "$file"; then
    fail "$file contains: $text"
  fi
}

make_fake_commands() {
  local bin_dir="$TEST_DIR/fake-bin"
  mkdir -p "$bin_dir"
  cat >"$bin_dir/tmux" <<'FAKE_TMUX'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"$FAKE_TMUX_LOG"
case ${1:-} in
  set|set-option)
    case " $* " in
      *" -t ="*) exit 2 ;;
    esac
    ;;
  split-window|select-layout|list-panes)
    case " $* " in
      *" -t ="*":agents "*) exit 2 ;;
    esac
    ;;
esac
case ${1:-} in
  has-session)
    [ "${FAKE_TMUX_MODE:-}" != launch ]
    ;;
  show-options)
    case " $* " in
      *" -t ="*) exit 2 ;;
      *" @peon_brief "*) printf '%s\n' "${FAKE_TMUX_BRIEF:-}"; exit 0 ;;
    esac
    [ "${FAKE_TMUX_MODE:-}" = owned ] && printf '1\n'
    exit 0
    ;;
  list-panes)
    case "$*" in
      *'#{pane_id} #{pane_current_command} #{@peon_name}'*)
        printf '%%1 codex impl\n'
        ;;
      *'#{pane_id}'*)
        for ((p = 1; p <= ${FAKE_TMUX_PANES:-1}; p++)); do
          printf '%%%d\n' "$p"
        done
        ;;
      *'#{@peon_name}'*)
        [ "${FAKE_TMUX_MODE:-}" = legacy ] && printf 'impl\n'
        ;;
    esac
    ;;
  display)
    case "$*" in
      *cursor_y*) printf '1\n' ;;
      *pane_in_mode*) printf '%s\n' "${FAKE_IN_MODE:-0}" ;;
      *) printf '%s\n' "${FAKE_TMUX_CMD:-zsh}" ;;
    esac
    ;;
  capture-pane)
    cap=${FAKE_TMUX_CAPTURE:-}
    # What the pane shows once a paste has reached it, when the test sets one.
    grep -Fq paste-buffer "$FAKE_TMUX_LOG" && cap=${FAKE_TMUX_CAPTURE_AFTER:-$cap}
    printf '%s\n' "$cap"
    ;;
  load-buffer)
    content=$(cat)
    printf 'buffer-content:%s\n' "$content" >>"$FAKE_TMUX_LOG"
    exit "${FAKE_LOAD_BUFFER_EXIT:-0}"
    ;;
esac
FAKE_TMUX
  cat >"$bin_dir/sleep" <<'FAKE_SLEEP'
#!/usr/bin/env bash
exit 0
FAKE_SLEEP
  chmod +x "$bin_dir/tmux" "$bin_dir/sleep"
  printf '%s\n' "$bin_dir"
}

# A tmux stand-in for send: the pane keeps its before-the-paste look until a
# paste is logged, then keeps it for FAKE_SETTLE more box reads before showing
# the box the message landed in. A box read is one cursor lookup followed by
# one capture, so the capture count is the number of polls send made.
make_send_bin() {
  local fake_bin=$1 bin_dir="$TEST_DIR/send-bin"
  mkdir -p "$bin_dir"
  cp "$fake_bin/sleep" "$bin_dir/sleep"
  cat >"$bin_dir/tmux" <<'FAKE_TMUX'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_TMUX_LOG"
pane=%1
case "$*" in *%2*) pane=%2 ;; esac
state=before
grep -Fq paste-buffer "$FAKE_TMUX_LOG" && state=after
reads=0
[ -f "$FAKE_TMUX_LOG.reads" ] && reads=$(cat "$FAKE_TMUX_LOG.reads")
box=$FAKE_BOX
cursor=$FAKE_CURSOR
in_mode=${FAKE_IN_MODE:-0}
if [ "$state" = after ]; then
  in_mode=${FAKE_IN_MODE_AFTER:-0}
  if [ "$reads" -ge "${FAKE_SETTLE:-0}" ]; then
    box=$FAKE_BOX_AFTER
    cursor=$FAKE_CURSOR_AFTER
  fi
fi
case ${1:-} in
  display)
    case "$*" in
      *pane_current_command*) printf '%s\n' "${FAKE_CMD:-node}" ;;
      *pane_in_mode*) printf '%s\n' "$in_mode" ;;
      *cursor_x*) printf '%s\n' "$cursor" ;;
      *cursor_y*) printf '%s\n' "${cursor##* }" ;;
    esac
    ;;
  capture-pane)
    printf '%s\n' "$box"
    [ "$state" = after ] && printf '%s' "$((reads + 1))" >"$FAKE_TMUX_LOG.reads"
    ;;
  show-options) printf '%s\n' "${FAKE_PEON_NAME-impl}" ;;
  load-buffer) printf 'buffer-content:%s\n' "$(cat)" >>"$FAKE_TMUX_LOG" ;;
  paste-buffer)
    # A pane named in FAKE_PASTE_FAIL refuses the paste.
    [ "$pane" = "${FAKE_PASTE_FAIL:-}" ] && exit 1
    ;;
esac
exit 0
FAKE_TMUX
  chmod +x "$bin_dir/tmux"
  printf '%s\n' "$bin_dir"
}

# A fake tmux for the slash-command subcommands: it echoes back whatever was
# pasted into a pane until an Enter submits it.
write_slash_fake_tmux() {
  local bin_dir=$1 fake_bin=$2
  mkdir -p "$bin_dir"
  cp "$fake_bin/sleep" "$bin_dir/sleep"
  cat >"$bin_dir/tmux" <<'FAKE_TMUX'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_TMUX_LOG"
pane=%1
case "$*" in *%2*) pane=%2 ;; esac
box=$FAKE_BOX
[ "$pane" = %2 ] && box=$FAKE_BOX2
# A pane shows what was pasted into it once the paste has reached it, and
# empties the box again once an Enter submits it.
pastes=$(grep -c -- "-dpt $pane" "$FAKE_TMUX_LOG")
enters=$(grep -c -Fx -- "send-keys -t $pane Enter" "$FAKE_TMUX_LOG")
if [ "$pastes" -gt "$enters" ]; then
  box="output line
❯ $(grep -F 'buffer-content:' "$FAKE_TMUX_LOG" | tail -1 | cut -d: -f2-)
────"
fi
case ${1:-} in
  has-session) ;;
  show-options)
    case "$*" in
      *@peon_brief*) printf '%s\n' "${FAKE_TMUX_BRIEF:-}" ;;
      *) printf '1\n' ;;
    esac
    ;;
  list-panes) printf '%s\n' "${FAKE_PANES:-%1 node impl}" ;;
  display)
    case "$*" in
      *pane_in_mode*) printf '0\n' ;;
      *cursor_y*) printf '1\n' ;;
    esac
    ;;
  capture-pane)
    printf '%s\n' "$box"
    # A pane that keeps redrawing: every capture differs, so it never settles.
    [ -n "${FAKE_UNSETTLED:-}" ] && printf 'redrawing %s\n' "$(wc -l <"$FAKE_TMUX_LOG")"
    ;;
  load-buffer) printf 'buffer-content:%s\n' "$(cat)" >>"$FAKE_TMUX_LOG" ;;
  paste-buffer)
    # A pane named in FAKE_PASTE_FAIL refuses the paste.
    [ "$pane" = "${FAKE_PASTE_FAIL:-}" ] && exit 1
    ;;
esac
exit 0
FAKE_TMUX
  chmod +x "$bin_dir/tmux"
}
