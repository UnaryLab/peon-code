#!/usr/bin/env bash
set -euo pipefail
CASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/helpers.sh
. "$CASE_DIR/../helpers.sh"

# The library functions under test, loaded with the two names they expect
# from the launcher.
SCRIPT_DIR=$ROOT
die() { echo "die: $*" >&2; exit 1; }
# shellcheck source=lib/config.sh
. "$ROOT/lib/config.sh"
# shellcheck source=lib/resume.sh
. "$ROOT/lib/resume.sh"
# shellcheck source=lib/watch.sh
. "$ROOT/lib/watch.sh"

# The context size is the last usage record: claude sums the input and both
# cache fields, codex reads the last request's input tokens.
test_context_tokens() {
  local claude="$TEST_DIR/claude.jsonl" codex="$TEST_DIR/codex.jsonl" empty="$TEST_DIR/empty.jsonl"
  printf '%s\n' \
    '{"type":"assistant","message":{"usage":{"input_tokens":5,"cache_creation_input_tokens":100,"cache_read_input_tokens":1000,"output_tokens":9}}}' \
    '{"type":"user","message":{"content":"hi"}}' \
    '{"type":"assistant","message":{"usage":{"input_tokens":2,"cache_creation_input_tokens":41,"cache_read_input_tokens":109350,"output_tokens":27,"output_tokens_details":{"thinking_tokens":0}}}}' \
    >"$claude"
  [ "$(context_tokens claude "$claude")" = 109393 ] || fail "claude context is not the sum of the last usage record"
  printf '%s\n' \
    '{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":2306308},"last_token_usage":{"input_tokens":58851,"cached_input_tokens":58624,"output_tokens":28,"total_tokens":58879},"model_context_window":258400}}}' \
    '{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":2400000},"last_token_usage":{"input_tokens":61000,"cached_input_tokens":60000,"output_tokens":28,"total_tokens":61028},"model_context_window":258400}}}' \
    >"$codex"
  [ "$(context_tokens codex "$codex")" = 61000 ] || fail "codex context is not the last request's input tokens"
  : >"$empty"
  [ -z "$(context_tokens claude "$empty")" ] || fail "an empty transcript reported a context size"
  [ -z "$(context_tokens copilot "$codex")" ] || fail "an unknown CLI reported a context size"
}

# compact-at is the one setting line in a team config: a number, 0 to turn
# the watcher off; anything else aborts.
test_compact_at_directive() {
  local conf="$TEST_DIR/compact-at.conf"
  printf 'compact-at 120000\nlead ./missing-agent manager\nimpl ./missing-agent implementer\ncheck ./missing-agent reviewer\n' >"$conf"
  COMPACT_AT=250000
  NAMES=(); CMDS=(); ROLES=(); MAIN_INDEX=-1
  read_conf "$conf"
  [ "$COMPACT_AT" = 120000 ] || fail "compact-at did not set the threshold"
  [ ${#NAMES[@]} -eq 3 ] || fail "compact-at line was counted as an agent"
  printf 'compact-at soon\nlead ./missing-agent manager\n' >"$conf"
  if (NAMES=(); CMDS=(); ROLES=(); MAIN_INDEX=-1; read_conf "$conf") 2>"$TEST_DIR/compact-at.err"; then
    fail "a non-numeric compact-at was accepted"
  fi
  assert_contains "$TEST_DIR/compact-at.err" "compact-at takes one number of tokens"
}

# A launch records each pane's CLI binary for the watcher and starts the
# watcher once, guarded by the threshold; watch itself exits when the
# session is gone.
test_watch_launch() {
  local fake_bin=$1 home_dir="$TEST_DIR/home-watch" config_dir="$TEST_DIR/watch-config"
  local work_dir="$TEST_DIR/watch-work" log="$TEST_DIR/tmux-watch.log" block
  local session="peon-watch-test-$$"
  mkdir -p "$home_dir" "$config_dir" "$work_dir"
  printf 'lead ./missing-agent manager\ncheck ./missing-agent reviewer\nimpl codex implementer\n' >"$config_dir/team.conf"
  (
    cd "$work_dir"
    PATH="$fake_bin:$PATH" HOME="$home_dir" TMPDIR="$TEST_DIR" \
      FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=launch FAKE_TMUX_PANES=3 \
      "$ROOT/peon-code.sh" -c "$config_dir/team.conf" "$session"
  ) >"$TEST_DIR/watch.out" 2>"$TEST_DIR/watch.err" </dev/null || true
  assert_contains "$log" "set -pt %1 @peon_bin ./missing-agent"
  assert_contains "$log" "set -pt %3 @peon_bin codex"
  block=$(sed -n '/^# The context watcher outlives this launch/,/^fi$/p' "$ROOT/lib/launch.sh")
  [ -n "$block" ] || fail "lib/launch.sh does not start the watcher"
  # shellcheck disable=SC2016  # source text to match, not an expansion
  assert_contains <(printf '%s\n' "$block") 'if [ "$COMPACT_AT" -gt 0 ]; then'
  # shellcheck disable=SC2016
  assert_contains <(printf '%s\n' "$block") 'watch "$SESSION" "$COMPACT_AT"'

  # No session: watch returns at once instead of looping.
  (
    cd "$work_dir"
    PATH="$fake_bin:$PATH" HOME="$home_dir" FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=launch \
      "$ROOT/peon-code.sh" watch gone-session 1000
  ) >"$TEST_DIR/watch-gone.out" 2>"$TEST_DIR/watch-gone.err" </dev/null ||
    fail "watch on a missing session exited non-zero"
  (
    cd "$work_dir"
    PATH="$fake_bin:$PATH" HOME="$home_dir" FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=launch \
      "$ROOT/peon-code.sh" watch "$session/none" 1000
  ) >"$TEST_DIR/watch-slash.out" 2>"$TEST_DIR/watch-slash.err" </dev/null ||
    fail "watch on a missing slash session exited non-zero when its PID file could not be written"
  if (PATH="$fake_bin:$PATH" "$ROOT/peon-code.sh" watch gone-session soon) 2>"$TEST_DIR/watch-bad.err"; then
    fail "watch accepted a non-numeric threshold"
  fi
  assert_contains "$TEST_DIR/watch-bad.err" "watch takes a number of tokens"
}

# One watch tick per pane: the transcript is looked up once and then kept, so
# the second tick reads the cached path, and the lookup itself writes no
# error (a pane id like %0 must survive the sed that reads the cache).
test_watch_loop() {
  local claude="$TEST_DIR/claude.jsonl" lookups="$TEST_DIR/lookups" err="$TEST_DIR/watch-loop.err" ticks=0
  local session="peon-watch-loop-$$"
  : >"$lookups"
  tmux() {
    case $1 in
      has-session) ticks=$((ticks + 1)); [ "$ticks" -le 2 ] ;;
      show-options) case $* in *@peon_bin*) echo claude ;; esac ;;
      *) return 0 ;;
    esac
  }
  session_name() { echo "$1"; }
  list_agent_panes() { printf '%%0 lead\n'; }
  last_thread_file() { echo x >>"$lookups"; echo "$claude"; }
  sleep() { :; }
  cmd_watch "$session" 1000000 2>"$err" || fail "watch loop exited non-zero"
  [ "$ticks" -eq 3 ] || fail "watch loop ran $ticks has-session checks, expected 3"
  [ "$(wc -l <"$lookups")" -eq 1 ] || fail "transcript looked up $(wc -l <"$lookups") times, expected 1 (cache missed)"
  [ ! -s "$err" ] || fail "watch loop wrote to stderr: $(cat "$err")"
  [ ! -e "/tmp/peon-code-watch-$UID/$session.pid" ] || fail "watch loop left its PID file"
  unset -f tmux session_name list_agent_panes last_thread_file sleep
}

# Launch only signals a recorded watcher for this exact session. All process
# checks and signals here are mocks, including malformed or foreign PIDs.
# shellcheck disable=SC2034,SC2317 # Variables and mocks are used by the evaluated launch block.
test_watch_launch_pid() (
  local SESSION="peon-watch-launch-$$" COMPACT_AT=1000 BRIEF_DIR=$TEST_DIR
  local pid_file="/tmp/peon-code-watch-$UID/$SESSION.pid" block args pid
  local log="$TEST_DIR/watch-signals.log" started="$TEST_DIR/watch-started.log"
  local checks="$TEST_DIR/watch-process-checks.log"
  trap 'rm -f "$pid_file"' EXIT
  (umask 077; mkdir -p "/tmp/peon-code-watch-$UID")
  block=$(sed -n '/^# The context watcher outlives this launch/,/^fi$/p' "$ROOT/lib/launch.sh")
  ps() {
    printf '%s\n' "$*" >>"$checks"
    printf '%s\n' "$args"
  }
  kill() { printf '%s\n' "$*" >>"$log"; }
  nohup() { printf '%s\n' "$*" >>"$started"; }
  for args in "bash $ROOT/peon-code.sh watch $SESSION 1000" \
    "bash $ROOT/peon-code.sh watch ${SESSION}more 1000" \
    "bash foreign.sh watch $SESSION 1000"; do
    : >"$log"
    : >"$checks"
    printf '12345\n' >"$pid_file"
    eval "$block"
    wait
    [ "$(cat "$checks")" = '-ww -o args= -p 12345' ] || fail "launch did not verify the recorded PID"
    if [ "$args" = "bash $ROOT/peon-code.sh watch $SESSION 1000" ]; then
      [ "$(cat "$log")" = '-TERM 12345' ] || fail "launch did not stop the recorded watcher"
    else
      [ ! -s "$log" ] || fail "launch signaled a foreign process or session"
    fi
  done
  for pid in "" bad 0 -1 '12345 extra' "$$"; do
    : >"$log"
    : >"$checks"
    printf '%s\n' "$pid" >"$pid_file"
    eval "$block"
    wait
    [ ! -s "$log" ] || fail "launch signaled invalid PID '$pid'"
    [ ! -s "$checks" ] || fail "launch checked invalid PID '$pid'"
  done
  [ "$(wc -l <"$started")" -eq 9 ] || fail "launch did not start each replacement watcher"
)

# Newest watcher wins: a second watcher on the same session takes the
# @peon_watch_pid session option, and the first one exits on its next tick
# instead of running beside it. Uses a real tmux session, killed by name.
test_watch_owner() (
  local session="peon-watch-owner-$$" a="" b="" owner i
  local pid_file="/tmp/peon-code-watch-$UID/$session.pid"
  trap 'tmux kill-session -t "=$session" 2>/dev/null || true; kill $a $b 2>/dev/null || true' EXIT
  tmux new-session -d -s "$session" || fail "could not create tmux session $session"
  PEON_WATCH_TICK=1 "$ROOT/peon-code.sh" watch "$session" 1000 2>/dev/null &
  a=$!
  for i in 1 2 3 4 5; do
    owner=$(tmux show-options -qv -t "=$session:" @peon_watch_pid)
    [ "$owner" = "$a" ] && break
    sleep 1
  done
  [ "$owner" = "$a" ] || fail "first watcher did not register: owner '$owner', expected $a"
  PEON_WATCH_TICK=1 "$ROOT/peon-code.sh" watch "$session" 1000 2>/dev/null &
  b=$!
  for i in 1 2 3 4 5; do
    owner=$(tmux show-options -qv -t "=$session:" @peon_watch_pid)
    [ "$owner" = "$b" ] && break
    sleep 1
  done
  [ "$owner" = "$b" ] || fail "second watcher did not take over: owner '$owner', expected $b"
  for i in 1 2 3 4 5; do
    kill -0 "$a" 2>/dev/null || break
    sleep 1
  done
  if kill -0 "$a" 2>/dev/null; then fail "stale watcher $a still runs beside $b"; fi
  wait "$a" || fail "stale watcher exited non-zero"
  a=""
  kill -0 "$b" 2>/dev/null || fail "newest watcher $b exited"
  [ "$(cat "$pid_file")" = "$b" ] || fail "stale watcher removed the newer PID file"
  tmux kill-session -t "=$session"
  wait "$b" || fail "newest watcher exited non-zero"
  b=""
  [ ! -e "$pid_file" ] || fail "newest watcher left its PID file"
)

fake_bin=$(make_fake_commands)
test_context_tokens
test_watch_loop
test_watch_launch_pid
test_watch_owner
test_compact_at_directive
test_watch_launch "$fake_bin"
echo "watch: PASS"
