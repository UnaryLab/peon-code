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

# shellcheck disable=SC2317 # goto_session calls the private terminal fixture.
test_goto_session_joins_windows() (
  local bin_dir="$TEST_DIR/attach-bin" log="$TEST_DIR/attach.log" saved_order live_order expected_order attached action
  mkdir -p "$bin_dir"
  cat >"$bin_dir/tmux" <<'TMUX'
#!/bin/sh
printf '%s\n' "$*" >>"$ATTACH_LOG"
case $1 in
  show-options) case "$*" in *window-size) printf 'manual\n' ;; *) printf '%s\n' "$SAVED_ORDER" ;; esac ;;
  list-panes) case "$*" in *' -s '*) printf '%%10\n%%2\n%%1\n' ;; *) cat "$ATTACH_ORDER" ;; esac ;;
  display-message)
    if grep -Fxq -- "$4" "$ATTACH_ORDER"; then printf 'agents\n'; else printf 'p%s\n' "${4#%}"; fi ;;
  join-pane)
    awk -v pane="$4" 'NR == 1 {print; print pane; next} {print}' "$ATTACH_ORDER" >"$ATTACH_ORDER.tmp"
    mv "$ATTACH_ORDER.tmp" "$ATTACH_ORDER" ;;
  swap-pane)
    awk -v source="$4" -v target="$6" '{if ($0 == source) print target; else if ($0 == target) print source; else print}' "$ATTACH_ORDER" >"$ATTACH_ORDER.tmp"
    mv "$ATTACH_ORDER.tmp" "$ATTACH_ORDER" ;;
esac
TMUX
  chmod +x "$bin_dir/tmux"
  # shellcheck source=lib/session.sh
  source "$ROOT/lib/session.sh"
  # Exercise the TTY path without needing an interactive test runner.
  function [ { case "$*" in '-t 0 ]') return 0 ;; '! -t 0 ]') return 1 ;; *) builtin [ "$@" ;; esac; }
  export ATTACH_LOG="$log" SAVED_ORDER ATTACH_ORDER="$TEST_DIR/attach-order"
  for saved_order in '%1 %2 %10' '%10 %1 %2' '%1 %99 %2 %10' '%99 %10 %1 %2' ''; do
    SAVED_ORDER=$saved_order
    live_order=${saved_order/'%99 '/}
    if [ -n "$live_order" ]; then expected_order='%10 %2'; else expected_order='%2 %10'; fi
    [ "$live_order" != '%1 %2 %10' ] || expected_order='%2 %10'
    for attached in '' existing-client; do
      : >"$log"
      printf '%%1\n' >"$ATTACH_ORDER"
      (PATH="$bin_dir:$PATH" TMUX="$attached" goto_session team)
      [ "$(sed -n 's/^join-pane -d -s \([^ ]*\) -t team:agents$/\1/p' "$log" | tr '\n' ' ')" = "$expected_order " ] || fail 'attach joined panes in the wrong order'
      [ "$(tr '\n' ' ' <"$ATTACH_ORDER")" = "${live_order:-%1 %2 %10} " ] || fail 'attach did not restore the true pane order'
      assert_not_contains "$log" '%99'
      action=attach
      [ -z "$attached" ] || action=switch-client
      tail -5 "$log" >"$TEST_DIR/attach-tail"
      cat >"$TEST_DIR/attach-expected" <<EXPECTED
set -w -t team:agents -u window-size
set-option -w -t team:agents main-pane-width 60%
select-layout -t team:agents main-vertical
set-option -u -t team @peon_pane_order
$action -t =team
EXPECTED
      cmp -s "$TEST_DIR/attach-tail" "$TEST_DIR/attach-expected" || fail 'attach did not restore layout before attaching'
    done
  done
)
test_goto_session_joins_windows
echo "session join: PASS"
