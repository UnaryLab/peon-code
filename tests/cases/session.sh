#!/usr/bin/env bash
set -euo pipefail
CASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/helpers.sh
. "$CASE_DIR/../helpers.sh"

test_session_ownership() {
  local fake_bin=$1 log="$TEST_DIR/tmux-ownership.log" home_dir="$TEST_DIR/home-tmux"
  mkdir -p "$home_dir"

  if PATH="$fake_bin:$PATH" HOME="$home_dir" FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=foreign \
    "$ROOT/peon-code.sh" dismiss foreign >"$TEST_DIR/foreign.out" 2>"$TEST_DIR/foreign.err"; then
    fail "dismiss accepted a foreign session"
  fi
  assert_contains "$TEST_DIR/foreign.err" "session foreign was not created by peon-code"
  if grep -Fq "kill-session" "$log"; then
    fail "dismiss killed a foreign session"
  fi

  : >"$log"
  PATH="$fake_bin:$PATH" HOME="$home_dir" FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=owned \
    "$ROOT/peon-code.sh" dismiss owned >"$TEST_DIR/owned.out"
  assert_contains "$log" "kill-session -t =owned"

  : >"$log"
  if PATH="$fake_bin:$PATH" HOME="$home_dir" FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=legacy \
    "$ROOT/peon-code.sh" dismiss legacy >"$TEST_DIR/legacy.out" 2>"$TEST_DIR/legacy.err"; then
    fail "dismiss accepted an unmarked legacy session"
  fi
  assert_contains "$TEST_DIR/legacy.err" "session legacy was not created by peon-code"
  if grep -Fq "kill-session" "$log"; then
    fail "dismiss killed an unmarked legacy session"
  fi
}

test_detach() {
  local fake_bin=$1 log="$TEST_DIR/tmux-detach.log" home_dir="$TEST_DIR/home-detach"
  mkdir -p "$home_dir"

  PATH="$fake_bin:$PATH" HOME="$home_dir" FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=owned \
    "$ROOT/peon-code.sh" detach owned >"$TEST_DIR/detach.out"
  assert_contains "$log" "detach-client -s =owned"
  assert_not_contains "$log" "kill-session"

  : >"$log"
  if PATH="$fake_bin:$PATH" HOME="$home_dir" FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=launch \
    "$ROOT/peon-code.sh" detach gone >"$TEST_DIR/detach-gone.out" 2>"$TEST_DIR/detach-gone.err"; then
    fail "detach exited 0 with no session"
  fi
  assert_contains "$TEST_DIR/detach-gone.err" "no session gone"
  assert_not_contains "$log" "detach-client"

  : >"$log"
  if PATH="$fake_bin:$PATH" HOME="$home_dir" FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=foreign \
    "$ROOT/peon-code.sh" detach foreign >"$TEST_DIR/detach-foreign.out" 2>"$TEST_DIR/detach-foreign.err"; then
    fail "detach accepted a foreign session"
  fi
  assert_contains "$TEST_DIR/detach-foreign.err" "session foreign was not created by peon-code"
  assert_not_contains "$log" "detach-client"
}

test_usage_includes_child_threads() (
  local store="$TEST_DIR/child usage" work codex_dir claude_dir report
  local CODEX_HOME="$store/codex" CLAUDE_CONFIG_DIR="$store/claude"
  export CODEX_HOME CLAUDE_CONFIG_DIR
  work="$store/work"
  mkdir -p "$work" "$CODEX_HOME/sessions"
  cd "$work"
  codex_dir="$CODEX_HOME/sessions"
  claude_dir="$CLAUDE_CONFIG_DIR/projects/${PWD//[^A-Za-z0-9]/-}"
  mkdir -p "$claude_dir/parent/subagents"
  # shellcheck source=lib/resume.sh
  source "$ROOT/lib/resume.sh"
  # shellcheck source=lib/session.sh
  source "$ROOT/lib/session.sh"
  printf '{"type":"session_meta","payload":{"id":"parent","cwd":"%s"}}\nagent cx of peon-code session child-test,\n{"total_token_usage":{"input_tokens":15,"cached_input_tokens":5,"cache_write_input_tokens":2,"output_tokens":3}}\n' "$PWD" >"$codex_dir/parent.jsonl"
  printf '{"type":"session_meta","payload":{"id":"child1","parent_thread_id":"parent","thread_source":"subagent","cwd":"%s"}}\nagent cx of peon-code session child-test,\n{"total_token_usage":{"input_tokens":30,"cached_input_tokens":10,"cache_write_input_tokens":4,"output_tokens":6}}\n' "$PWD" >"$codex_dir/child1.jsonl"
  printf '{"type":"session_meta","payload":{"id":"child2","parent_thread_id":"child1","thread_source":"guardian_review","source":{"subagent":{"other":"guardian"}},"cwd":"%s"}}\nagent cx of peon-code session child-test,\n{"total_token_usage":{"input_tokens":45,"cached_input_tokens":15,"cache_write_input_tokens":6,"output_tokens":9}}\n' "$PWD" >"$codex_dir/child2.jsonl"
  printf '{"type":"session_meta","payload":{"id":"expired","parent_thread_id":"parent"}}\n{"total_token_usage":{"input_tokens":1000,"output_tokens":1000}}\n' >"$codex_dir/expired.jsonl"
  touch -t 200001010000 "$codex_dir/expired.jsonl"
  if cli_call codex child_threads "$codex_dir/parent.jsonl" | grep -F -- "$codex_dir/expired.jsonl" >/dev/null; then fail 'Codex included an expired parent-linked child'; fi
  printf 'agent cc of peon-code session child-test,\n{"requestId":"own","usage":{"input_tokens":10,"cache_read_input_tokens":5,"cache_creation_input_tokens":2,"output_tokens":3}}\n' >"$claude_dir/parent.jsonl"
  printf '{"requestId":"child1","usage":{"input_tokens":20,"cache_read_input_tokens":10,"cache_creation_input_tokens":4,"output_tokens":6}}\n' >"$claude_dir/parent/subagents/agent-child1.jsonl"
  printf '{"requestId":"child2","usage":{"input_tokens":30,"cache_read_input_tokens":15,"cache_creation_input_tokens":6,"output_tokens":9}}\n' >"$claude_dir/parent/subagents/agent-child2.jsonl"
  mkdir -p "$claude_dir/other/subagents"
  printf '{"requestId":"unrelated","usage":{"input_tokens":1000,"cache_read_input_tokens":1000,"cache_creation_input_tokens":1000,"output_tokens":1000}}\n' >"$claude_dir/other/subagents/agent-x.jsonl"
  # shellcheck disable=SC2317 # print_usage calls these private tmux fixtures.
  list_agent_panes() { printf '%%1 cx\n%%2 cc\n'; }
  # shellcheck disable=SC2317
  tmux() {
    case $1 in
      show-options) case $4 in %1) printf 'codex\n' ;; %2) printf 'claude\n' ;; esac ;;
      display) printf '%s\n' "$work" ;;
    esac
  }
  report="$TEST_DIR/child-usage.out"
  print_usage child-test >"$report"
  assert_contains "$report" 'cx         codex    input 60 cache read 30 cache write 12 output 18 total 120'
  assert_contains "$report" 'cc         claude   input 60 cache read 30 cache write 12 output 18 total 120'
  [ "$(grep -c '^  cx ' "$report")" = 1 ] || fail 'child usage added extra pane lines'
  [ "$(grep -c '^  cc ' "$report")" = 1 ] || fail 'child usage added extra pane lines'
  [ "$(cli_usage_sum codex "$codex_dir/parent.jsonl")" = '60 30 12 18' ] || fail 'Codex did not include guardian descendant'
  [ "$(cli_usage_sum claude "$claude_dir/parent.jsonl")" = '60 30 12 18' ] || fail 'Claude did not include both children'
  [ "$(cli_call codex context_tokens "$codex_dir/parent.jsonl")" = '' ] || fail 'child usage changed parent context'

  local child_paths index previous depth_dir="$codex_dir/depth space"
  mkdir -p "$depth_dir"
  printf '{"type":"session_meta","payload":{"id":"depth-root","parent_thread_id":"depth-5"}}\n' >"$depth_dir/own.jsonl"
  previous=depth-root
  for ((index=1; index<=6; index++)); do
    printf '{"type":"session_meta","payload":{"id":"depth-%s","parent_thread_id":"%s"}}\n' "$index" "$previous" >"$depth_dir/child $index.jsonl"
    previous="depth-$index"
  done
  child_paths=$(cli_call codex child_threads "$depth_dir/own.jsonl")
  [ "$(printf '%s\n' "$child_paths" | wc -l | tr -d ' ')" = 5 ] || fail 'Codex child traversal did not stop at depth 5'
  [ "$(printf '%s\n' "$child_paths" | sort -u | wc -l | tr -d ' ')" = 5 ] || fail 'Codex child traversal repeated paths'
  assert_contains <(printf '%s\n' "$child_paths") "$depth_dir/child 5.jsonl"
  assert_not_contains <(printf '%s\n' "$child_paths") "$depth_dir/child 6.jsonl"
  assert_not_contains <(printf '%s\n' "$child_paths") "$depth_dir/own.jsonl"

  local diamond_dir="$codex_dir/diamond"
  mkdir -p "$diamond_dir"
  printf '{"type":"session_meta","payload":{"id":"diamond-root"}}\n' >"$diamond_dir/own.jsonl"
  for index in 1 2; do
    printf '{"type":"session_meta","payload":{"id":"diamond-shared","parent_thread_id":"diamond-root"}}\n' >"$diamond_dir/child-$index.jsonl"
  done
  printf '{"type":"session_meta","payload":{"id":"diamond-root","parent_thread_id":"diamond-shared"}}\n' >"$diamond_dir/cycle.jsonl"
  child_paths=$(cli_call codex child_threads "$diamond_dir/own.jsonl")
  [ "$(printf '%s\n' "$child_paths" | wc -l | tr -d ' ')" = 3 ] || fail 'Codex cycle or repeated IDs duplicated paths'
  [ "$(printf '%s\n' "$child_paths" | sort -u | wc -l | tr -d ' ')" = 3 ] || fail 'Codex cyclic traversal did not keep paths unique'
)

test_usage_sum_counts_each_path_once() (
  # shellcheck source=lib/cli.sh
  source "$ROOT/lib/cli.sh"
  # shellcheck disable=SC2317 # The dispatcher calls these private provider fixtures.
  counting_usage_tokens() {
    case $1 in
      own) printf '01 02 03 04\n' ;;
      child) printf '10 20 30 40\n' ;;
      invalid) printf '9 -2 3 4\n' ;;
      failed) return 1 ;;
      *) printf '1 2 3\n' ;;
    esac
  }
  # shellcheck disable=SC2317
  counting_child_threads() { printf 'own\nchild\nchild\ninvalid\nfailed\n'; }
  [ "$(cli_usage_sum counting own)" = '11 22 33 44' ] || fail 'usage sum counted repeated or invalid children'
  [ "$(cli_usage_sum counting own)" = '11 22 33 44' ] || fail 'usage dedup state leaked between calls'
  # shellcheck disable=SC2317
  plain_usage_tokens() { printf '1 2 3 4\n'; }
  [ "$(cli_usage_sum plain own)" = '1 2 3 4' ] || fail 'missing child concern lost own usage'
  if cli_call plain child_threads own; then fail 'missing child concern succeeded'; fi
  # shellcheck disable=SC2317
  counting_child_threads() { fail 'invalid own usage enumerated children'; }
  [ "$(cli_usage_sum counting invalid)" = '' ] || fail 'invalid own usage produced a total'
  [ "$(cli_usage_sum counting missing)" = '' ] || fail 'malformed own usage produced a total'
)

test_usage_includes_child_threads
test_usage_sum_counts_each_path_once
fake_bin=$(make_fake_commands)
test_session_ownership "$fake_bin"
test_detach "$fake_bin"
echo "session: PASS"
