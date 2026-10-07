#!/usr/bin/env bash
set -euo pipefail
CASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/helpers.sh
. "$CASE_DIR/../helpers.sh"

fake_bin=$(make_fake_commands)
KEY_BIN=$(make_send_bin "$fake_bin")
KEY_LOG="$TEST_DIR/tmux-key.log"
menu='Choose an option
❯ 1. Continue
  2. Cancel'

run_key() {
  local submit=""
  if [ "${1:-}" = --submit ]; then submit=--submit; shift; fi
  local name=$1
  shift
  : >"$KEY_LOG"
  PATH="$KEY_BIN:$PATH" FAKE_TMUX_LOG="$KEY_LOG" FAKE_BOX="$menu" FAKE_CURSOR='2 1' \
    env "$@" "$ROOT/peon-code.sh" key ${submit:+"$submit"} %2 "$name" >"$TEST_DIR/key.out" 2>"$TEST_DIR/key.err"
}

for name in Tab Up Down Enter Escape 1 2 3 4 5 6 7 8 9; do
  run_key "$name"
  assert_contains "$KEY_LOG" "send-keys -t %2 $name"
  [ "$(grep -c '^send-keys' "$KEY_LOG")" = 1 ] || fail "key sent $name more than once"
  assert_not_contains "$KEY_LOG" 'paste-buffer'
done

run_key Enter FAKE_BOX="${menu/❯/  ❯}"
[ "$(grep -c -Fx 'send-keys -t %2 Enter' "$KEY_LOG")" = 1 ] || fail 'indented Claude menu did not take Enter once'

run_key --submit Enter FAKE_BOX='❯ half-typed text' FAKE_CURSOR='2 0'
[ "$(grep -c -Fx 'send-keys -t %2 Enter' "$KEY_LOG")" = 1 ] || fail 'nonempty input box did not take Enter once'
run_key --submit Enter
[ "$(grep -c -Fx 'send-keys -t %2 Enter' "$KEY_LOG")" = 1 ] || fail 'submit flag did not answer a menu once'

run_key Enter FAKE_BOX='Choose a model
› 1. Model A
  2. Model B

enter select / esc back' FAKE_CURSOR='2 4'
[ "$(grep -c -Fx 'send-keys -t %2 Enter' "$KEY_LOG")" = 1 ] || fail 'Codex footer-cursor menu did not take Enter once'

for name in C-c 0 10 ''; do
  rc=0
  run_key "$name" || rc=$?
  [ "$rc" -eq 2 ] || fail "unknown key '$name' returned $rc instead of 2"
  assert_contains "$TEST_DIR/key.err" 'allowed keys: Tab, Up, Down, Enter, Escape, 1..9'
  assert_not_contains "$KEY_LOG" 'send-keys'
done

assert_key_refused() {
  local submit=""
  if [ "${1:-}" = --submit ]; then submit=--submit; shift; fi
  local name=$1 reason=$2
  shift 2
  if run_key ${submit:+"$submit"} "$name" "$@"; then fail "key accepted $reason"; fi
  assert_contains "$TEST_DIR/key.err" "$reason"
  assert_not_contains "$KEY_LOG" 'send-keys'
}

assert_key_refused Enter 'not on a menu' FAKE_BOX='❯ half-typed text' FAKE_CURSOR='2 0'
assert_key_refused Enter 'not on a menu' FAKE_BOX='❯' FAKE_CURSOR='2 0'
assert_key_refused Enter 'not on a menu' FAKE_BOX='› 1. Quoted choice
❯' FAKE_CURSOR='2 1'
assert_key_refused --submit Enter 'nothing to submit' FAKE_BOX='❯' FAKE_CURSOR='2 0'
assert_key_refused Enter 'cannot read input box' FAKE_CURSOR='2 invalid'
assert_key_refused Enter 'cannot read input box' FAKE_CURSOR='2 99'
assert_key_refused --submit Enter 'cannot read input box' FAKE_CURSOR='2 invalid'
assert_key_refused --submit Enter 'cannot read input box' FAKE_BOX='> unreadable input' FAKE_CURSOR='2 0'
assert_key_refused Tab 'not a peon-code agent pane' FAKE_PEON_NAME=
assert_key_refused Tab 'back at a shell' FAKE_CMD=bash
assert_key_refused Tab 'in copy mode' FAKE_IN_MODE=1
assert_key_refused Enter 'in copy mode' FAKE_IN_MODE=1
assert_key_refused --submit Enter 'in copy mode' FAKE_IN_MODE=1
assert_key_refused Tab 'agent changed' PEON_EXPECTED_IDENTITY=100:1:200

# shellcheck source=lib/delivery.sh
source "$ROOT/lib/delivery.sh"
test_key_held_lock() {
  local name rc
  for name in Tab Escape 1 Enter; do
    rc=0
    run_key "$name" || rc=$?
    [ "$rc" -eq 75 ] || fail "key $name returned $rc while another delivery held the pane"
    assert_contains "$TEST_DIR/key.err" 'another delivery owns %2'
    assert_not_contains "$KEY_LOG" 'send-keys'
  done
  assert_key_refused --submit Enter 'another delivery owns %2'
}
PATH="$KEY_BIN:$PATH" FAKE_TMUX_LOG="$KEY_LOG" with_pane_delivery %2 test_key_held_lock

echo 'key: PASS'
