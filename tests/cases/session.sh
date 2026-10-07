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

fake_bin=$(make_fake_commands)
test_session_ownership "$fake_bin"
test_detach "$fake_bin"
echo "session: PASS"
