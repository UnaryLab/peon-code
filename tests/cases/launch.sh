#!/usr/bin/env bash
set -euo pipefail
CASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/helpers.sh
. "$CASE_DIR/../helpers.sh"

test_unique_buffers_and_launch_failure() {
  local fake_bin=$1 log="$TEST_DIR/tmux-buffer.log" home_dir="$TEST_DIR/home-buffer"
  mkdir -p "$home_dir" "$TEST_DIR/work"

  # The pane here shows an empty box but never shows the paste, so the run
  # ends nonzero; what this case checks is the buffer name.
  PATH="$fake_bin:$PATH" HOME="$home_dir" FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=owned \
    FAKE_TMUX_CAPTURE=$'output line\n❯\n────' \
    "$ROOT/peon-code.sh" msg all hello owned >"$TEST_DIR/msg.out" 2>"$TEST_DIR/msg.err" || true
  grep -Eq 'load-buffer -b peon-code-[0-9]+-1 -' "$log" ||
    fail "msg did not use a unique tmux buffer"

  : >"$log"
  (
    cd "$TEST_DIR/work"
    PATH="$fake_bin:$PATH" HOME="$home_dir" TMPDIR="$TEST_DIR" \
      FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=launch \
      "$ROOT/peon-code.sh" launch ./missing-agent
  ) >"$TEST_DIR/launch.out" 2>"$TEST_DIR/launch.err" </dev/null &&
    fail "a launch with a dead agent succeeded"
  assert_contains "$TEST_DIR/launch.err" "agents failed to start; killed session launch: ./missing-agent"
  assert_contains "$log" "set-option -t launch @peon_code 1"
  assert_contains "$log" "set -pt %1 @peon_role_type"
  assert_contains "$log" "list-panes -t launch:agents"
  assert_contains "$log" "kill-session -t =launch"
  assert_not_contains "$log" "set-option -t =launch"
  assert_not_contains "$TEST_DIR/launch.out" "session launch is ready"
  grep -Eq 'buffer-content:\./missing-agent .*/0\.md' "$log" ||
    fail "a numeric brief filename was not used"
  grep -Eq 'load-buffer -b peon-code-[0-9]+-1 -' "$log" ||
    fail "agent launch did not use a unique tmux buffer"
  if grep -Fq "/./missing-agent.md" "$TEST_DIR/launch.err"; then
    fail "a slash-containing command was used as a brief filename"
  fi
}

# A launch into panes whose shell prompt draws the same marker a CLI does:
# the command line is submitted anyway, since the shell prompt is not a box
# peon-code can check, and a brief the box never shows leaves the run going.
test_launch_with_prompt_box() {
  local fake_bin=$1 log="$TEST_DIR/tmux-prompt-box.log" home_dir="$TEST_DIR/home-prompt-box"
  local work_dir="$TEST_DIR/prompt-box-work"
  # A shell prompt ending in the marker, with a clock on the right, so the box
  # reads back non-empty and never matches what was pasted.
  local prompt_box='work on main
❯ [12:34:56]'
  mkdir -p "$home_dir" "$work_dir"
  printf 'boss claude -\n' >"$work_dir/peon-code.conf"

  : >"$log"
  (
    cd "$work_dir"
    PATH="$fake_bin:$PATH" HOME="$home_dir" TMPDIR="$TEST_DIR" \
      FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=launch FAKE_TMUX_CMD=node \
      FAKE_TMUX_CAPTURE="$prompt_box" \
      "$ROOT/peon-code.sh" prompt-box
  ) >"$TEST_DIR/prompt-box.out" 2>"$TEST_DIR/prompt-box.err" </dev/null ||
    fail "launch gave up on a pane whose shell prompt draws a box"
  assert_contains "$TEST_DIR/prompt-box.out" "session prompt-box is ready"
  assert_contains "$log" "buffer-content:claude"
  assert_contains "$TEST_DIR/prompt-box.err" \
    "no brief sent: input or another delivery is busy for boss %1"
  # One Enter: the command line got it, the brief did not.
  [ "$(grep -c -Fx -- 'send-keys -t %1 Enter' "$log")" = 1 ] ||
    fail "launch pressed the wrong number of Enters into a pane with a prompt box"
}

# Headless: every agent is started before the attach line is printed, so a
# script calling the launcher gets back a session whose panes are running.
# The launcher's own output appends to the tmux log, so one file holds both
# streams in the order they happened.
test_headless_launch_order() {
  local fake_bin=$1 log="$TEST_DIR/tmux-order.log" home_dir="$TEST_DIR/home-order"
  local work_dir="$TEST_DIR/order-work" launch_line ready_line
  local prompt_box='work on main
❯ [12:34:56]'
  mkdir -p "$home_dir" "$work_dir"
  printf 'boss claude -\n' >"$work_dir/peon-code.conf"

  : >"$log"
  # shellcheck disable=SC2094  # both streams append to the one file on purpose
  (
    cd "$work_dir"
    PATH="$fake_bin:$PATH" HOME="$home_dir" TMPDIR="$TEST_DIR" \
      FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=launch FAKE_TMUX_CMD=node \
      FAKE_TMUX_CAPTURE="$prompt_box" \
      "$ROOT/peon-code.sh" order-test
  ) >>"$log" 2>"$TEST_DIR/order.err" </dev/null ||
    fail "the headless launch failed"
  launch_line=$(grep -n -F "buffer-content:claude" "$log" | tail -1 | cut -d: -f1)
  ready_line=$(grep -n -F "session order-test is ready" "$log" | cut -d: -f1)
  [ -n "$launch_line" ] || fail "the headless launch logged no agent launch"
  [ -n "$ready_line" ] || fail "the headless launch printed no attach line"
  [ "$launch_line" -lt "$ready_line" ] ||
    fail "the attach line came before the agents were launched"
  # The border label reads @peon_name, which an agent CLI cannot overwrite.
  assert_contains "$log" "pane-border-format"
  assert_contains "$log" "#{@peon_name}"
  # Headless notes stay on stderr: nothing goes to the status line.
  if grep '^display-message ' "$log" | grep -vq '^display-message -p '; then fail "headless launch posted a status message"; fi
}

test_all_commands_before_readiness() {
  local fake_bin=$1 bin_dir="$TEST_DIR/launch-order-bin" state_dir="$TEST_DIR/launch-order-state"
  local log="$TEST_DIR/all-launches.log" home_dir="$TEST_DIR/home-all-launches"
  local work_dir="$TEST_DIR/all-launches-work" pane launch_line ready_line brief_line
  mkdir -p "$bin_dir" "$state_dir" "$home_dir" "$work_dir"
  cp "$fake_bin/sleep" "$bin_dir/sleep"
  cat >"$bin_dir/tmux" <<'FAKE_TMUX'
#!/usr/bin/env bash
case ${1:-} in
  display)
    if [ "${4:-}" = '#{pane_current_command}' ]; then
      if [ -f "$LAUNCH_STATE/$3.launched" ]; then
        printf 'ready-check:%s\n' "$3" >>"$FAKE_TMUX_LOG"
        printf 'node\n'
      else
        printf 'zsh\n'
      fi
      exit 0
    fi
    ;;
  send-keys)
    if [ "${4:-}" = Enter ] && [ ! -f "$LAUNCH_STATE/$3.launched" ]; then
      : >"$LAUNCH_STATE/$3.launched"
      printf 'launch-enter:%s\n' "$3" >>"$FAKE_TMUX_LOG"
    fi
    ;;
  load-buffer)
    cat >"$LAUNCH_STATE/$3"
    "$LAUNCH_BASE_TMUX" "$@" <"$LAUNCH_STATE/$3"
    exit $?
    ;;
  paste-buffer)
    if [ -f "$LAUNCH_STATE/$5.launched" ]; then
      cp "$LAUNCH_STATE/$3" "$LAUNCH_STATE/$5.brief"
      printf 'brief-paste:%s:%s\n' "$5" "$(head -1 "$LAUNCH_STATE/$5.brief")" >>"$FAKE_TMUX_LOG"
    fi
    ;;
  capture-pane)
    if [ -s "$LAUNCH_STATE/$3.brief" ]; then
      printf 'output\n❯ [Pasted text #1]\n────\n'
    else
      printf 'output\n❯\n────\n'
    fi
    exit 0
    ;;
esac
exec "$LAUNCH_BASE_TMUX" "$@"
FAKE_TMUX
  chmod +x "$bin_dir/tmux"
  printf 'compact-at 0\nfirst claude -\nsecond claude -\nlast codex -\n' >"$work_dir/peon-code.conf"
  : >"$log"
  (
    cd "$work_dir"
    PATH="$bin_dir:$PATH" HOME="$home_dir" TMPDIR="$TEST_DIR" \
      LAUNCH_STATE="$state_dir" LAUNCH_BASE_TMUX="$fake_bin/tmux" \
      FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=launch FAKE_TMUX_PANES=3 \
      "$ROOT/peon-code.sh" all-launches
  ) >"$TEST_DIR/all-launches.out" 2>"$TEST_DIR/all-launches.err" </dev/null || fail 'multi-pane launch failed'
  ready_line=$(grep -n '^ready-check:' "$log" | head -1 | cut -d: -f1)
  brief_line=$(grep -n '^brief-paste:' "$log" | head -1 | cut -d: -f1)
  [[ -n $ready_line && -n $brief_line ]] || fail 'launch did not check readiness and paste briefs'
  for pane in %1 %2 %3; do
    launch_line=$(grep -n -Fx "launch-enter:$pane" "$log" | cut -d: -f1)
    [ -n "$launch_line" ] || fail "$pane did not launch"
    [ "$launch_line" -lt "$ready_line" ] || fail "$pane launched after the first readiness wait"
    [ "$launch_line" -lt "$brief_line" ] || fail "$pane launched after the first Claude brief"
  done
  assert_contains "$log" 'brief-paste:%1:You are first (claude), agent first'
  assert_contains "$log" 'brief-paste:%2:You are second (claude), agent second'
}

# Attached, the session goes up first and the launch notes become status-line
# messages, leaving a failed agent's pane in view instead of killing it.
# A TTY cannot be faked portably, so this reads the wiring out of the source.
test_attached_launch_notes() {
  local block
  block=$(sed -n '/^if \[ -t 0 \]; then$/,/^else$/p' "$ROOT/lib/launch.sh")
  [ -n "$block" ] || fail "lib/launch.sh has no attached-launch branch"
  # The launch runs in the background and its notes go to the session's client.
  assert_contains <(printf '%s\n' "$block") "launch_agents"
  assert_contains <(printf '%s\n' "$block") "done >/dev/null 2>&1 &"
  # shellcheck disable=SC2016  # source text to match, not an expansion
  assert_contains <(printf '%s\n' "$block") \
    'tmux display-message -d 10000 -c "$client"'
  # The user is looking at the failed pane, so the session stays up.
  assert_not_contains <(printf '%s\n' "$block") "kill-session"
}

test_codex_normal_screen() {
  local fake_bin=$1 work_dir="$TEST_DIR/codex-normal-work" home_dir="$TEST_DIR/home-codex-normal"
  local log="$TEST_DIR/codex-normal.log" mode launch plain own
  mkdir -p "$work_dir" "$home_dir/.codex/sessions"
  work_dir=$(cd "$work_dir" && pwd)
  printf 'plain codex -\nown codex --no-alt-screen --model test -\n' >"$work_dir/peon-code.conf"
  printf '{"cwd":"%s"}\nagent plain of peon-code session codex-normal, in pane\n' "$work_dir" \
    >"$home_dir/.codex/sessions/rollout-11111111-1111-1111-1111-111111111111.jsonl"
  printf '{"cwd":"%s"}\nagent own of peon-code session codex-normal, in pane\n' "$work_dir" \
    >"$home_dir/.codex/sessions/rollout-22222222-2222-2222-2222-222222222222.jsonl"
  for mode in fresh resume; do
    : >"$log"
    (
      cd "$work_dir"
      set -- codex-normal
      [ "$mode" != resume ] || set -- resume codex-normal
      PATH="$fake_bin:$PATH" HOME="$home_dir" CODEX_HOME="$home_dir/.codex" TMPDIR="$TEST_DIR" \
        FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=launch FAKE_TMUX_PANES=2 \
        "$ROOT/peon-code.sh" "$@"
    ) >"$TEST_DIR/codex-normal.out" 2>"$TEST_DIR/codex-normal.err" </dev/null || true
    plain=$(grep -F 'buffer-content:codex' "$log" | sed -n '1p')
    own=$(grep -F 'buffer-content:codex' "$log" | sed -n '2p')
    [ -n "$plain" ] && [ -n "$own" ] || fail "both Codex panes were not launched"
    for launch in "$plain" "$own"; do
      [ "$(printf '%s\n' "$launch" | grep -o -- '--no-alt-screen' | wc -l | tr -d ' ')" = 1 ] || fail "Codex did not receive --no-alt-screen exactly once: $launch"
    done
    assert_contains "$log" '--model test'
    if [ "$mode" = resume ]; then
      assert_contains "$log" 'buffer-content:codex resume 11111111-1111-1111-1111-111111111111 --no-alt-screen'
      assert_contains "$log" 'buffer-content:codex resume 22222222-2222-2222-2222-222222222222 --no-alt-screen --model test'
    fi
  done
}

fake_bin=$(make_fake_commands)
test_unique_buffers_and_launch_failure "$fake_bin"
test_launch_with_prompt_box "$fake_bin"
test_headless_launch_order "$fake_bin"
test_all_commands_before_readiness "$fake_bin"
test_attached_launch_notes
test_codex_normal_screen "$fake_bin"
echo "launch: PASS"
