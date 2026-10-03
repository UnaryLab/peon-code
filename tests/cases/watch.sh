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
  COMPACT_AT=270000
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
  mkdir -p "$home_dir" "$config_dir" "$work_dir"
  printf 'lead ./missing-agent manager\ncheck ./missing-agent reviewer\nimpl codex implementer\n' >"$config_dir/team.conf"
  (
    cd "$work_dir"
    PATH="$fake_bin:$PATH" HOME="$home_dir" TMPDIR="$TEST_DIR" \
      FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=launch FAKE_TMUX_PANES=3 \
      "$ROOT/peon-code.sh" -c "$config_dir/team.conf" watch-test
  ) >"$TEST_DIR/watch.out" 2>"$TEST_DIR/watch.err" </dev/null || true
  assert_contains "$log" "set -pt %1 @peon_bin ./missing-agent"
  assert_contains "$log" "set -pt %3 @peon_bin codex"
  block=$(sed -n '/^# The context watcher outlives this launch/,/^fi$/p' "$ROOT/peon-code.sh")
  [ -n "$block" ] || fail "peon-code.sh does not start the watcher"
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
  if (PATH="$fake_bin:$PATH" "$ROOT/peon-code.sh" watch gone-session soon) 2>"$TEST_DIR/watch-bad.err"; then
    fail "watch accepted a non-numeric threshold"
  fi
  assert_contains "$TEST_DIR/watch-bad.err" "watch takes a number of tokens"
}

fake_bin=$(make_fake_commands)
test_context_tokens
test_compact_at_directive
test_watch_launch "$fake_bin"
echo "watch: PASS"
