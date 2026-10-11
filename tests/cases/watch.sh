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
  # shellcheck disable=SC2030 # Invalid config parsing is isolated from later provider mocks.
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
  assert_contains <(printf '%s\n' "$block") 'if [ "$COMPACT_AT" -gt 0 ] || [ "$RESTART_DEAD" = yes ]; then'
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

# Changed transcripts wait for the shared read beat. Cached paths keep their
# per-pane lookup interval; missing paths are retried every scan.
test_watch_loop() (
  local claude="$TEST_DIR/watch transcript.jsonl" lookup_log="$TEST_DIR/lookups" err="$TEST_DIR/watch-loop.err" ticks=0
  local session="peon-watch-loop-$$" read_log="$TEST_DIR/watch-reads" owners="$TEST_DIR/watch-owners" PEON_WATCH_MIN=60
  local usage_log="$TEST_DIR/watch-usage-reads"
  : >"$claude"
  : >"$lookup_log"
  : >"$read_log"
  : >"$owners"
  : >"$usage_log"
  tmux() {
    case $1 in
      display) echo 100 ;;
      has-session)
        ticks=$((ticks + 1))
        case $ticks in 3|8) printf 'change\n' >>"$claude" ;; esac
        [ "$ticks" -le 8 ] ;;
      show-options)
        case $* in
          *@peon_bin*) echo claude ;;
          *@peon_watch_pid*) printf '%s\n' "$ticks" >>"$owners" ;;
        esac ;;
      *) return 0 ;;
    esac
  }
  session_name() { echo "$1"; }
  list_agent_panes() { printf '%%0 lead\n%%1 late\n'; }
  last_thread_file() {
    [ -f "$3" ] || fail 'watch lookup has no session timestamp reference'
    printf '%s %s\n' "$ticks" "$1" >>"$lookup_log"
    case $1 in *'agent late '*) [ "$ticks" -ge 5 ] || return 0 ;; esac
    echo "$claude"
  }
  context_tokens() { printf '%s\n' "$ticks" >>"$read_log"; echo 100; }
  # shellcheck disable=SC2317 # cli_call invokes the provider by name.
  claude_usage_tokens() { printf '%s\n' "$ticks" >>"$usage_log"; echo '1 2 3 4'; }
  date() {
    if [ "$1" != +%s ]; then command date "$@"; return; fi
    case $ticks in
      1) echo 100 ;; 2) echo 105 ;; 3) echo 110 ;; 4) echo 159 ;;
      5) echo 160 ;; 6) echo 165 ;; 7) echo 220 ;; 8) echo 225 ;;
    esac
  }
  sleep() { [ "$1" = 5 ] || fail "watch scan interval was $1, expected 5"; }
  cmd_watch "$session" 1000000 2>"$err" || fail "watch loop exited non-zero"
  [ "$ticks" -eq 9 ] || fail "watch loop ran $ticks has-session checks, expected 9"
  [ "$(cat "$read_log")" = "$(printf '1\n5\n5\n')" ] || fail "watch read unchanged transcripts or read outside the shared beat: $(cat "$read_log")"
  [ "$(cat "$usage_log")" = "$(cat "$read_log")" ] || fail 'watch read usage outside a full transcript read'
  [ "$(cat "$lookup_log")" = "$(printf '1 agent lead of peon-code session %s,\n1 agent late of peon-code session %s,\n2 agent late of peon-code session %s,\n3 agent late of peon-code session %s,\n4 agent late of peon-code session %s,\n5 agent lead of peon-code session %s,\n5 agent late of peon-code session %s,\n7 agent lead of peon-code session %s,\n7 agent late of peon-code session %s,\n' "$session" "$session" "$session" "$session" "$session" "$session" "$session" "$session" "$session")" ] || fail "watch missed an empty retry or refreshed a cached path inside its interval: $(cat "$lookup_log")"
  [ "$(wc -l <"$owners")" -eq 8 ] || fail 'watch skipped an ownership check'
  [ ! -s "$err" ] || fail "watch loop wrote to stderr: $(cat "$err")"
  [ ! -e "/tmp/peon-code-watch-$UID/$session.pid" ] || fail "watch loop left its PID file"
)

# Invalid or unavailable usage leaves the pane's last valid option intact.
test_watch_usage() (
  local transcript="$TEST_DIR/watch-usage.jsonl" log="$TEST_DIR/watch-usage-options"
  local session="peon-watch-usage-$$" ticks=0 PEON_WATCH_MIN=0
  : >"$transcript"
  : >"$log"
  tmux() {
    case $1 in
      display) echo 100 ;;
      has-session)
        ticks=$((ticks + 1))
        printf 'change\n' >>"$transcript"
        [ "$ticks" -le 10 ]; return ;;
      show-options) case $* in *@peon_bin*) echo claude ;; esac ;;
      set) [ "$4" != @peon_usage ] || printf '%s\n' "$*" >>"$log" ;;
    esac
    return 0
  }
  session_name() { echo "$1"; }
  list_agent_panes() { printf '%%0 lead\n'; }
  last_thread_file() { echo "$transcript"; }
  context_tokens() { :; }
  # shellcheck disable=SC2317 # cli_call invokes the provider by name.
  claude_usage_tokens() {
    case $ticks in
      1) echo '12 34 56 78' ;; 2) : ;; 3) echo '-1 2 3 4' ;;
      4) echo '1.5 2 3 4' ;; 5) echo '1 2 3 4 5' ;; 6) echo '1 2 3' ;;
      7) echo '1  2 3 4' ;; 8) printf '1\t2 3 4\n' ;;
      9) echo '1 2 3 4'; return 1 ;; 10) echo '0 0 0 0' ;;
    esac
  }
  sleep() { :; }
  cmd_watch "$session" 1000000 || fail 'usage watch failed without context tokens'
  [ "$(cat "$log")" = "$(printf 'set -pt %%0 @peon_usage 12 34 56 78\nset -pt %%0 @peon_usage 0 0 0 0\n')" ] ||
    fail "watch wrote invalid usage or missed valid usage: $(cat "$log")"
)

# Transcript lookup must keep a pane's first brief, even when newer threads
# inherit it or quote it in a later message.
# shellcheck disable=SC2034,SC2317 # Provider lookup hooks use dynamic scope.
test_watch_parent_transcript() (
  local actual_bin=$1 variant=$2 ticks=0 session="peon-watch-parent-$1-$2-$$"
  local store="$TEST_DIR/parent-$1-$2" parent child other marker log context_log line stamp selected
  local CODEX_HOME="$TEST_DIR/codex-home-$1-$2" second
  [ "$variant" != totals ] || store="$CODEX_HOME/sessions"
  marker="agent lead of peon-code session $session,"
  parent="$store/parent.jsonl"
  child="$store/parent/subagents/agent-child.jsonl"
  other="$store/other.jsonl"
  log="$store/options"
  context_log="$store/context"
  mkdir -p "${child%/*}"
  : >"$log"
  : >"$context_log"
  if [ "$actual_bin" = codex ]; then
    child="$store/child.jsonl"
    printf '{"type":"session_meta","payload":{"id":"parent","cwd":"%s","thread_source":"cli"}}\n' "$PWD" >"$parent"
    printf '{"type":"event_msg","payload":{"type":"user_message","message":"%s"}}\n' "$marker" >>"$parent"
    printf '%s\n' '{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":30,"cached_input_tokens":7,"output_tokens":9},"last_token_usage":{"input_tokens":17}},"rate_limits":{"secondary":{"window_minutes":10080,"used_percent":31,"resets_at":123}}}}' >>"$parent"
    if [ "$variant" = guardian ]; then
      printf '{"type":"session_meta","payload":{"cwd":"%s","thread_source":"guardian_review","source":{"subagent":{"other":"guardian"}},"parent_thread_id":"parent"}}\n' "$PWD" >"$child"
    else
      printf '{"type":"session_meta","payload":{"cwd":"%s","thread_source":"subagent"}}\n' "$PWD" >"$child"
    fi
    sed -n '2p' "$parent" >>"$child"
    printf '{"type":"session_meta","payload":{"cwd":"%s"}}\n{"type":"event_msg","payload":{"type":"user_message","message":"agent other of peon-code session %s,"}}\n' "$PWD" "$session" >"$other"
  else
    printf '{"type":"user","message":{"content":"%s"}}\n' "$marker" >"$parent"
    printf '%s\n' '{"type":"assistant","requestId":"p1","message":{"usage":{"input_tokens":11,"cache_read_input_tokens":3,"cache_creation_input_tokens":2,"output_tokens":5}}}' >>"$parent"
    head -n 1 "$parent" >"$child"
    printf '{"type":"user","message":{"content":"agent other of peon-code session %s,"}}\n' "$session" >"$other"
  fi
  if [ "$variant" = totals ]; then
    second="${child%/*}/agent-second.jsonl"
    if [ "$actual_bin" = codex ]; then
      printf '{"type":"session_meta","payload":{"id":"child","cwd":"%s","parent_thread_id":"parent","thread_source":"subagent"}}\n' "$PWD" >"$child"
      printf '{"type":"session_meta","payload":{"id":"guardian","cwd":"%s","parent_thread_id":"child","thread_source":"guardian_review","source":{"subagent":{"other":"guardian"}}}}\n' "$PWD" >"$second"
      printf '%s\n' '{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":2,"cache_write_input_tokens":1,"output_tokens":4},"last_token_usage":{"input_tokens":2000000}},"rate_limits":{"secondary":{"window_minutes":10080,"used_percent":95,"resets_at":999}}}}' >>"$child"
      printf '%s\n' '{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":20,"cached_input_tokens":3,"cache_write_input_tokens":2,"output_tokens":5},"last_token_usage":{"input_tokens":2000000}}}}' >>"$second"
    else
      printf '%s\n' '{"type":"assistant","requestId":"c1","message":{"usage":{"input_tokens":7,"cache_read_input_tokens":2,"cache_creation_input_tokens":1,"output_tokens":4}}}' >>"$child"
      printf '%s\n' '{"type":"assistant","requestId":"c2","message":{"usage":{"input_tokens":13,"cache_read_input_tokens":5,"cache_creation_input_tokens":3,"output_tokens":6}}}' >"$second"
      printf '%s\n' '{"type":"assistant","message":{"usage":{"input_tokens":2000000}}}' >>"$child"
      mkdir -p "$store/other-session/subagents"
      printf '%s\n' '{"type":"assistant","requestId":"other","message":{"usage":{"input_tokens":50000,"cache_read_input_tokens":100,"cache_creation_input_tokens":20,"output_tokens":900}}}' >"$store/other-session/subagents/agent-x.jsonl"
    fi
  fi
  for line in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    printf '{"type":"assistant","message":{"content":"turn %s"}}\n' "$line" >>"$other"
  done
  printf '{"type":"user","message":{"content":"Quoted later: %s"}}\n' "$marker" >>"$other"
  stamp=$(date +%Y%m%d)
  touch -t "${stamp}0000" "$parent"
  touch -t "${stamp}0001" "$child"
  touch -t "${stamp}0002" "$other"
  case $variant in child|guardian) mv "$other" "$other.ignored" ;; esac
  claude_resume_dir() { dir=$store; }
  codex_resume_dir() { dir=$store; cwd="\"cwd\":\"$PWD\""; }
  selected=$(last_thread_file "$marker" "$actual_bin")
  [ "$selected" = "$parent" ] || fail "$actual_bin $variant lookup selected another thread: $selected"
  tmux() {
    case $1 in
      has-session) ticks=$((ticks + 1)); [ "$ticks" -le 1 ]; return ;;
      display) echo 100 ;;
      show-options) case $* in *@peon_bin*) echo "$actual_bin" ;; esac ;;
      set) case $4 in @peon_usage|@peon_weekly) printf '%s %s\n' "$4" "$5" >>"$log" ;; esac ;;
    esac
    return 0
  }
  session_name() { echo "$1"; }
  list_agent_panes() { printf '%%0 lead\n'; }
  context_tokens() {
    [ "$2" = "$parent" ] || fail 'watch context read a child or another pane'
    cli_call "$1" context_tokens "$2" | tee "$context_log"
  }
  sleep() { :; }
  cmd_watch "$session" 1000000 || fail "$actual_bin parent watch failed"
  if [ "$actual_bin" = codex ]; then
    [ "$(cat "$context_log")" = 17 ] || fail 'Codex context missed its parent'
    if [ "$variant" = totals ]; then assert_contains "$log" '@peon_usage 48 12 3 18'
    else assert_contains "$log" '@peon_usage 23 7 0 9'; fi
    assert_contains "$log" '@peon_weekly 31.0 123'
  else
    [ "$(cat "$context_log")" = 16 ] || fail 'Claude context missed its parent'
    if [ "$variant" = totals ]; then assert_contains "$log" '@peon_usage 31 10 6 15'
    else assert_contains "$log" '@peon_usage 11 3 2 5'; fi
    [ "$(wc -l <"$log")" -eq 1 ] || fail 'Claude parent lookup wrote unrelated options'
  fi
)

# Shared sums start fresh on every read and count each transcript once.
# shellcheck disable=SC2317 # CLI dispatch calls these test provider hooks.
test_watch_usage_children() (
  local store="$TEST_DIR/usage-children" own_file child_file second_file invalid_file total read
  mkdir -p "$store"
  own_file="$store/own_file"; child_file="$store/child_file"; second_file="$store/second_file"; invalid_file="$store/invalid_file"
  printf '1 2 3 4\n' >"$own_file"
  printf '5 6 7 8\n' >"$child_file"
  printf '9 10 11 12\n' >"$second_file"
  printf 'invalid\n' >"$invalid_file"
  copilot_usage_tokens() { cat "$1"; }
  copilot_child_threads() { printf '%s\n' "$own_file" "$child_file" "$child_file" "$invalid_file" "$second_file" "$own_file" "$second_file"; }
  watchtest_usage_tokens() { cat "$1"; }
  for read in 1 2; do
    total=$(cli_usage_sum copilot "$own_file")
    [ "$total" = '15 18 21 24' ] || fail "usage read $read counted a transcript twice or missed a child: $total"
  done
  [ "$(cli_usage_sum watchtest "$own_file")" = '1 2 3 4' ] || fail 'missing child concern lost own usage'
  [ -z "$(cli_usage_sum copilot "$invalid_file")" ] || fail 'invalid own usage accepted child totals'
)

# A waiting job owns its marker even when its owner path lies beyond a
# terminal-width ps listing. All process checks here are mocks.
# shellcheck disable=SC2317 # The reaper calls these command mocks.
test_watch_live_waiting_job() (
  local waiting_owner log="$TEST_DIR/live-waiting.log"
  waiting_owner="/tmp/$(printf '%0200d' 0)/swap.owner"
  : >"$log"
  tmux() {
    case $1 in
      show-options) case $* in
        *@peon_swap_pending*) echo 'waiting 456:100 claude --model chosen' ;;
        *@peon_watch_pid*) echo 123 ;;
        *@peon_swap_pid*) echo 456 ;;
        *@peon_swap_owner*) echo "$waiting_owner" ;;
        *@peon_swap_identity*) echo pane-identity ;;
      esac ;;
      display) echo test-session ;;
      display-message) echo pane-identity ;;
      set) printf '%s\n' "$*" >>"$log" ;;
    esac
  }
  kill() { [ "$*" = '-0 456' ] || fail 'reaper signaled an unexpected process'; }
  ps() {
    case " $* " in
      *' -ww '*) printf 'bash peon-code.sh __swap_job %%0 pane-identity %s lead claude\n' "$waiting_owner" ;;
      *) printf 'bash peon-code.sh __swap_job %%0 pane-identity /tmp/0000000000\n' ;;
    esac
  }
  if watch_swap_reap_locked %0; then fail 'a live waiting job was reaped'; fi
  [ ! -s "$log" ] || fail 'a live waiting job lost its marker'
)

# Restart-only watches leave startup shells alone, resume a dead pane once,
# and stop retrying after three restarts within the last hour.
# shellcheck disable=SC2317 # The watcher and provider dispatch call these mocks.
test_watch_restart() (
  local scenario=$1 ticks=0 max_ticks=5 current log="$TEST_DIR/restart-$1.log"
  local session="peon-watch-restart-$1-$$" brief="$TEST_DIR/restart-brief.md"
  local stored_launch='claude --model chosen' expected_rid="thread 'quoted'" expected
  local threshold=0 restart_tick=3
  local delivery_guard_held=no delivery_clear_seen=no
  local pending_file="$TEST_DIR/pending-$1" status_file="$TEST_DIR/swap-status-$1"
  : >"$pending_file"
  : >"$status_file"
  : >"$log"
  printf 'restart brief\n' >"$brief"
  : >"$TEST_DIR/restart.jsonl"
  case $scenario in
    cap) max_ticks=14 ;; swaps|cap_then_pending) max_ticks=12 ;; swaps_then_crash|hour) max_ticks=15 ;;
    pending_start) max_ticks=3; printf 'waiting %s:%s claude --model chosen\n' "$$" "$(date +%s)" >"$pending_file" ;;
    pending_failed_ready|pending_failed_brief|pending_paste_failed) max_ticks=4 ;;
    interrupted|bounced|capture_fail) restart_tick=5 ;;
    typed) restart_tick=4 ;; failed_ready) max_ticks=9 ;;
    cache) threshold=1000000 ;;
  esac
  tmux() {
    case $1 in
      has-session) ticks=$((ticks + 1)); [ "$ticks" -le "$max_ticks" ] ;;
      display)
        case $* in
          *session_created*) echo 100 ;;
          *session_name*) echo "$session" ;;
          *pane_current_command*)
            printf 'scan %s\n' "$ticks" >>"$log"
            current=bash
            case $scenario in
              initial) : ;;
              pending_start) : ;;
              swaps) case $ticks in 1|4|7|10) current=node ;; esac ;;
              swaps_then_crash) case $ticks in 1|4|7|10|13) current=node ;; esac ;;
              pending_failed_ready|pending_failed_brief|pending_paste_failed) [ "$ticks" -ne 1 ] || current=node ;;
              interrupted) case $ticks in 1) current=node ;; 3) current="" ;; esac ;;
              typed|capture_fail|failed_ready) [ "$ticks" -ne 1 ] || current=node ;;
              bounced) case $ticks in 1|3) current=node ;; esac ;;
              cap|hour|cap_then_pending) case $ticks in 1|4|7|10) current=node ;; esac ;;
              *) case $ticks in 1|4) current=node ;; 3) current=systemd-run ;; esac ;;
            esac
            case $scenario:$current in
              cap_then_pending:node)
                if [ "$ticks" -eq 10 ]; then
                  printf 'waiting %s:%s claude --model chosen\n' "$$" "$(date +%s)" >"$pending_file"
                  printf 'checking claude --model chosen\n' >"$status_file"
                fi ;;
              swaps:node|pending_failed_ready:node|pending_failed_brief:node|pending_paste_failed:node|swaps_then_crash:node)
                [ "$ticks" -ne 13 ] || { echo "$current"; return; }
                printf 'waiting %s:%s claude --model chosen\n' "$$" "$(date +%s)" >"$pending_file"
                printf 'checking claude --model chosen\n' >"$status_file" ;;
            esac
            echo "$current" ;;
        esac ;;
      display-message) echo pane-identity ;;
      capture-pane)
        printf 'capture %s\n' "$ticks" >>"$log"
        [ "$scenario" != capture_fail ] || [ "$ticks" -ne 3 ] || return 1
        if [ "$scenario" = typed ]; then
          case $ticks in 2) printf 'host$ e' ;; *) printf 'host$ ec' ;; esac
        else
          printf 'host$ '
        fi ;;
      send-keys)
        [ "$*" = 'send-keys -t %0 C-u' ] || fail 'restart sent an unexpected clear key'
        [ "$delivery_guard_held" = yes ] || fail 'restart cleared shell input outside the delivery lock'
        printf 'clear %s\n' "$ticks" >>"$log"
        [ "$scenario" != clear_failed ] || return 1
        delivery_clear_seen=yes ;;
      list-panes) printf '%%0 lead\n%%1\n' ;;
      show-options)
        case $* in
          *@peon_restart*)
            printf 'restart-option\n' >>"$log"
            case $scenario in disabled) echo 0 ;; *) echo 1 ;; esac ;;
          *@peon_bin*) echo claude ;;
          *@peon_swap_pending*) cat "$pending_file" ;;
          *@peon_swap_owner*) echo swap-owner ;;
          *@peon_swap_identity*) echo pane-identity ;;
          *@peon_watch_pid*) echo "$$" ;;
          *@peon_launch*) [ "$scenario" = empty_launch ] || echo "$stored_launch" ;;
          *@peon_brief*) echo "$brief" ;;
        esac ;;
      set)
        if [ "$2" = -pu ]; then
          [ "$5" != @peon_swap_pending ] || : >"$pending_file"
        else
          case $4 in
            @peon_swap_pending) printf '%s\n' "$5" >"$pending_file" ;;
            @peon_swap) printf '%s\n' "$5" >"$status_file"; printf 'swap-status %s\n' "$5" >>"$log" ;;
          esac
        fi ;;
      *) return 0 ;;
    esac
  }
  session_name() { echo "$1"; }
  last_thread_file() {
    [ "$1" = "agent lead of peon-code session $session," ] || fail 'restart lookup used the wrong marker'
    [ "$2" = claude ] || fail 'restart lookup missed its provider'
    [ -f "$3" ] || fail 'restart lookup missed its session reference'
    printf 'lookup %s\n' "$ticks" >>"$log"
    [ "$scenario" = fresh ] || echo "$TEST_DIR/restart.jsonl"
  }
  claude_resume_id() { echo "$expected_rid"; }
  claude_resume_args() {
    [ "$scenario" != unsupported ] || return 1
    printf ' --resume %s' "$1"
  }
  with_pane_delivery() {
    shift
    delivery_guard_held=yes
    delivery_clear_seen=no
    if "$@"; then delivery_guard_held=no; else delivery_guard_held=no; return 1; fi
  }
  launch_command_locked() {
    [ "$delivery_guard_held" = yes ] || fail 'restart pasted outside the delivery lock'
    [ "$delivery_clear_seen" = yes ] || fail 'restart pasted before clearing shell input'
    printf 'launch %s %s\n' "$1" "$2" >>"$log"
    printf 'paste %s\nEnter %s\n' "$ticks" "$ticks" >>"$log"
  }
  wait_agent_ready() {
    printf 'ready %s\n' "$1" >>"$log"
    [ "$scenario" != failed_ready ] && [ "$scenario" != pending_failed_ready ]
  }
  claude_brief_after_start() {
    [ "$i" -eq 0 ] || fail 'restart brief has wrong pane index'
    # shellcheck disable=SC2031 # watch_restart supplies its own local NAMES array.
    [ "${NAMES[$i]}" = lead ] || fail 'restart brief has wrong agent name'
    [ "${PANE_IDS[$i]}" = %0 ] || fail 'restart brief has wrong pane id'
    [ "$BRIEF" = 'restart brief' ] || fail 'restart did not read the stored brief'
    case $scenario in fresh|unsupported) [ -z "$RID" ] || fail 'fresh restart passed a resume id' ;;
      *) [ "$RID" = "$expected_rid" ] || fail 'resume brief missed its raw thread id' ;; esac
    printf 'brief %s\n' "$ticks" >>"$log"
    if [ "$scenario" = pending_paste_failed ]; then PASTE_RC=3; fi
    [ "$scenario" != pending_failed_brief ]
  }
  watch_note() { printf 'note %s\n' "$2" >>"$log"; }
  context_tokens() {
    [ "$scenario" = cache ] || fail 'restart-only watcher tried to compact'
    printf 'read %s\n' "$ticks" >>"$log"
    echo 100
  }
  date() {
    if [ "$1" != +%s ]; then command date "$@"; return; fi
    if [ "$scenario" = hour ] && [ "$ticks" -eq 15 ]; then echo 3700; else echo 100; fi
  }
  sleep() { :; }
  cmd_watch "$session" "$threshold" || fail "restart watch failed: $scenario"
  [ "$(grep -c '^restart-option$' "$log")" -eq 1 ] || fail 'watcher did not read restart option once'
  case $scenario in
    cap_then_pending)
      [ "$(grep -c '^launch ' "$log")" -eq 4 ] || fail 'pending swap did not bypass three prior crash restarts'
      [ "$(grep '^paste ' "$log")" = "$(printf 'paste 3\npaste 6\npaste 9\npaste 12\n')" ] || fail 'pending swap case did not follow three ordinary crashes'
      assert_contains "$log" 'brief 12'
      [ "$(cat "$status_file")" = 'done claude --model chosen' ] || fail 'pending swap after crash cap did not finish'
      assert_not_contains "$log" 'died 3 times' ;;
    swaps|swaps_then_crash|pending_start)
      expected=4
      [ "$scenario" != swaps_then_crash ] || expected=5
      [ "$scenario" != pending_start ] || expected=1
      [ "$(grep -c '^launch ' "$log")" = "$expected" ] || fail 'intentional restarts hit the crash cap or missed initial pending shell'
      assert_not_contains "$log" 'died 3 times'
      [ "$(cat "$status_file")" = 'done claude --model chosen' ] || fail 'intentional restart did not finish'
      awk '/^ready / { ready=1 } /^brief / { brief=1 } /^swap-status done / { if (!ready || !brief) exit 1; ready=0; brief=0 }' "$log" || fail 'swap done preceded readiness or brief' ;;
    pending_failed_ready|pending_failed_brief|pending_paste_failed)
      [ "$(grep -c '^launch ' "$log")" = 1 ] || fail 'failed intentional restart launched twice'
      assert_not_contains "$log" 'swap-status done '
      assert_contains "$status_file" 'failed:'
      [ ! -s "$pending_file" ] || fail 'failed intentional restart kept pending' ;;
    initial|disabled|empty_launch)
      assert_not_contains "$log" 'launch '
      assert_not_contains "$log" 'note '
      [ "$scenario" != disabled ] || [ "$ticks" -eq 0 ] || fail 'disabled threshold-zero watcher looped' ;;
    clear_failed)
      assert_contains "$log" 'clear 3'
      assert_not_contains "$log" 'launch '
      assert_not_contains "$log" 'paste '
      assert_not_contains "$log" 'Enter '
      assert_not_contains "$log" 'ready '
      assert_not_contains "$log" 'brief ' ;;
    cap|hour)
      expected=3
      [ "$scenario" != hour ] || expected=4
      [ "$(grep -c '^launch ' "$log")" -eq "$expected" ] || fail "restart cap failed: $(cat "$log")"
      [ "$(grep -c '^note lead died 3 times in an hour; left at shell$' "$log")" -eq 1 ] || fail 'restart cap note repeated or was missing'
      assert_not_contains "$log" 'brief 12'
      assert_not_contains "$log" 'brief 13'
      assert_not_contains "$log" 'brief 14' ;;
    failed_ready)
      [ "$(grep -c '^launch ' "$log")" -eq 3 ] || fail 'failed restarts did not retry three times'
      for restart_tick in 3 5 7; do
        [ "$(grep -c "^lookup $restart_tick$" "$log")" -eq 1 ] || fail 'failed restart skipped two stable shell scans'
      done
      assert_not_contains "$log" 'brief '
      assert_not_contains "$log" 'lookup 4'
      assert_not_contains "$log" 'lookup 6'
      [ "$(grep -c '^note lead died 3 times in an hour; left at shell$' "$log")" -eq 1 ] || fail 'failed restarts bypassed the cap' ;;
    *)
      [ "$(grep -c '^launch ' "$log")" -eq 1 ] || fail 'two shell scans did not cause exactly one restart'
      [ "$(grep -c "^brief $restart_tick$" "$log")" -eq 1 ] || fail 'restart missed its brief after readiness'
      case $scenario in
        fresh|unsupported) assert_contains "$log" "launch %0 $stored_launch"; assert_contains "$log" 'note lead died; restarting with fresh' ;;
        *) assert_contains "$log" "launch %0 claude --resume $(printf %q "$expected_rid") --model chosen"
           assert_contains "$log" 'note lead died; restarting with resume' ;;
      esac ;;
  esac
  if [ "$scenario" = cache ]; then
    [ "$(grep -c '^lookup 4$' "$log")" -eq 1 ] || fail 'restart did not clear the transcript lookup cache'
    [ "$(grep -c '^read 4$' "$log")" -eq 1 ] || fail 'restart did not clear the transcript read cache'
  fi
  case $scenario in typed|capture_fail)
    assert_not_contains "$log" 'lookup 3'
    assert_contains "$log" "capture $restart_tick" ;;
  esac
)

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
test_watch_usage
for bin in codex claude; do
  for variant in child late_marker; do test_watch_parent_transcript "$bin" "$variant"; done
done
test_watch_parent_transcript codex guardian
test_watch_parent_transcript codex totals
test_watch_parent_transcript claude totals
test_watch_usage_children
test_watch_live_waiting_job
for scenario in resume fresh unsupported initial disabled cap hour interrupted bounced cache typed capture_fail failed_ready empty_launch clear_failed swaps swaps_then_crash pending_start pending_failed_ready pending_failed_brief pending_paste_failed cap_then_pending; do
  test_watch_restart "$scenario"
done
test_watch_launch_pid
test_watch_owner
test_compact_at_directive
test_watch_launch "$fake_bin"
echo "watch: PASS"
