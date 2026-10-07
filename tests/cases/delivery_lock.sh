#!/usr/bin/env bash
# Test hooks are invoked by the sourced delivery helpers.
# shellcheck disable=SC2317
set -euo pipefail
CASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/helpers.sh
. "$CASE_DIR/../helpers.sh"

mkdir -p "$TEST_DIR/delivery-tmp"
export TMPDIR="$TEST_DIR/delivery-tmp" ROOT TEST_DIR
runner="$TEST_DIR/delivery-runner.sh"
cat >"$runner" <<'RUNNER'
#!/usr/bin/env bash
set -euo pipefail
source "$ROOT/lib/delivery.sh"
tmux() { printf '%s:%s\n' "$REVIEW_SOCKET" "$4"; }
callback() {
  printf '%s\n' "$REVIEW_LABEL" >>"$TEST_DIR/entered"
  case "$REVIEW_MODE" in
    hold)
      touch "$TEST_DIR/holding"
      while [ ! -f "$TEST_DIR/release" ]; do sleep 0.02; done ;;
    external)
      bash -c 'touch "$1/holding"; while [ ! -f "$1/release" ]; do sleep 0.02; done; printf "old-child\n" >>"$1/entered"; touch "$1/child-finished"' _ "$TEST_DIR" ;;
    fail) return 19 ;;
    nested) with_pane_delivery "$REVIEW_PANE" nested_callback ;;
  esac
}
nested_callback() { printf 'nested\n' >>"$TEST_DIR/entered"; }
with_pane_delivery "$REVIEW_PANE" callback
RUNNER

run_delivery() {
  REVIEW_SOCKET="$TEST_DIR/$1" REVIEW_PANE=$2 REVIEW_LABEL=$3 REVIEW_MODE=$4 bash "$runner"
}
lock_key=$(printf '%s:%%1' "$TEST_DIR/server-one" | cksum)
lock_dir=/tmp/peon-code-delivery-$UID/${lock_key%% *}
wait_holder() {
  local i
  for ((i = 0; i < 150; i++)); do
    [ ! -f "$TEST_DIR/holding" ] || return 0
    sleep 0.02
  done
  fail 'delivery holder never acquired its lock'
}

run_delivery server-one %1 first hold & holder=$!
trap 'kill "$holder" 2>/dev/null || true' EXIT
wait_holder
rc=0
run_delivery server-one %1 competing normal || rc=$?
[ "$rc" -eq 75 ] || fail "same-pane contention returned $rc instead of 75"
assert_not_contains "$TEST_DIR/entered" competing
run_delivery server-one %2 other-pane normal
run_delivery server-two %1 other-server normal
touch "$TEST_DIR/release"
wait "$holder"
run_delivery server-one %1 after-release normal
rc=0
run_delivery server-one %1 failing fail || rc=$?
[ "$rc" -eq 19 ] || fail 'delivery changed callback failure status'
run_delivery server-one %1 after-failure normal
run_delivery server-one %1 recursive nested
assert_contains "$TEST_DIR/entered" nested

# A killed guard can leave an external command running. Keep its lock until
# that child finishes and the caller explicitly removes this known test lock.
rm "$TEST_DIR/holding" "$TEST_DIR/release"
REVIEW_SOCKET="$TEST_DIR/server-one" REVIEW_PANE=%1 REVIEW_LABEL=killed REVIEW_MODE=external \
  bash "$runner" 2>"$TEST_DIR/killed-owner.err" & holder=$!
wait_holder
kill -KILL "$(cat "$lock_dir/owner")"
wait "$holder" 2>/dev/null || true
rc=0
run_delivery server-one %1 unsafe-after-kill normal || rc=$?
[ "$rc" -eq 75 ] || fail 'dead guard admitted a competing delivery while its child lived'
assert_not_contains "$TEST_DIR/entered" unsafe-after-kill
touch "$TEST_DIR/release"
for ((i = 0; i < 150; i++)); do
  [ ! -f "$TEST_DIR/child-finished" ] || break
  sleep 0.02
done
[ -f "$TEST_DIR/child-finished" ] || fail 'orphaned callback never finished'
assert_contains "$TEST_DIR/entered" old-child
rm "$lock_dir/owner"
rmdir "$lock_dir"
run_delivery server-one %1 after-explicit-cleanup normal

# TERM waits for the foreground callback to finish before releasing its lock.
rm "$TEST_DIR/holding" "$TEST_DIR/release" "$TEST_DIR/child-finished"
run_delivery server-one %1 terminated external & holder=$!
wait_holder
kill -TERM "$(cat "$lock_dir/owner")"
rc=0
run_delivery server-one %1 unsafe-after-term normal || rc=$?
[ "$rc" -eq 75 ] || fail 'TERM released a lock while its callback lived'
touch "$TEST_DIR/release"
wait "$holder" 2>/dev/null || true
run_delivery server-one %1 after-term normal
trap - EXIT

test_failed_explain_enter() (
  # shellcheck source=lib/input.sh
  source "$ROOT/lib/input.sh"
  # shellcheck source=lib/commands.sh
  source "$ROOT/lib/commands.sh"
  # shellcheck source=lib/mouse.sh
  source "$ROOT/lib/mouse.sh"
  # shellcheck source=lib/delivery.sh
  source "$ROOT/lib/delivery.sh"
  die() { echo "$*" >&2; exit 1; }
  tmux() {
    case $1 in
      display) echo codex ;;
      show-options) echo worker ;;
      send-keys) echo 'failed Enter' >&2; return 1 ;;
      display-message)
        if [ "$2" = -p ]; then printf '%s:%s\n' "$TEST_DIR/explain-server" "$4"; fi ;;
    esac
  }
  pane_box_ready() { return 0; }
  paste_only() { cat >/dev/null; }
  pane_box_text() { printf 'Explain what the following text means in this conversation: selected'; }
  pane_takes_keys() { return 0; }
  if printf selected | cmd_explain %1 >"$TEST_DIR/explain-failure" 2>&1; then
    fail 'explain reported success after tmux refused Enter'
  fi
  assert_contains "$TEST_DIR/explain-failure" 'failed Enter'
  assert_not_contains "$TEST_DIR/explain-failure" 'peon-code: sent to'
)
test_failed_explain_enter

test_failed_delivery_target() (
  source "$ROOT/lib/delivery.sh"
  tmux() { return 1; }
  rc=0
  with_pane_delivery %999 true >"$TEST_DIR/missing-pane.out" 2>&1 || rc=$?
  [ "$rc" -eq 75 ] || fail 'missing delivery target did not fail'
  assert_contains "$TEST_DIR/missing-pane.out" 'cannot deliver to pane %999'
)
test_failed_delivery_target

test_failed_slash_enter() (
  source "$ROOT/lib/commands.sh"
  state="$TEST_DIR/slash-readback"
  pane_takes_keys() { return 0; }
  pane_box_text() {
    if [ -f "$state" ]; then printf /clear; else touch "$state"; fi
  }
  paste_only() { cat >/dev/null; }
  sleep() { :; }
  tmux() { return 1; }
  if slash_locked %1 /clear; then
    fail 'slash command reported success after tmux refused Enter'
  fi
)
test_failed_slash_enter

test_slash_waits_for_redraw() (
  source "$ROOT/lib/commands.sh"
  local state="$TEST_DIR/slash-redraw" log="$TEST_DIR/slash-enter"
  printf '0\n' >"$state"
  pane_takes_keys() { return 0; }
  pane_box_text() {
    local reads
    reads=$(cat "$state")
    printf '%s\n' "$((reads + 1))" >"$state"
    case $reads in 1) printf /cle ;; 2) printf /clear ;; esac
  }
  paste_only() { cat >/dev/null; }
  sleep() { :; }
  tmux() { printf '%s\n' "$*" >>"$log"; }
  slash_locked %1 /clear || fail 'slash delivery stopped during its first redraw'
  [ "$(cat "$state")" = 3 ] || fail 'slash delivery did not wait for exact readback'
  assert_contains "$log" 'send-keys -t %1 Enter'
)
test_slash_waits_for_redraw

test_changed_agent_identity() (
  local stage=$1 state="$TEST_DIR/identity-$1" log="$TEST_DIR/identity-$1.log"
  # shellcheck source=lib/input.sh
  source "$ROOT/lib/input.sh"
  # shellcheck source=lib/commands.sh
  source "$ROOT/lib/commands.sh"
  # shellcheck source=lib/delivery.sh
  source "$ROOT/lib/delivery.sh"
  PEON_EXPECTED_IDENTITY=100:1:200
  printf '%s\n' "$PEON_EXPECTED_IDENTITY" >"$state"
  : >"$log"
  die() { echo "$*" >&2; exit 1; }
  tmux() {
    printf '%s\n' "$*" >>"$log"
    case $1 in
      display-message)
        if [ "$5" = '#{pid}:#{session_id}:#{pane_pid}' ]; then cat "$state"
        else printf '%s:%s\n' "$TEST_DIR/identity-$stage-server" "$4"; fi ;;
      display) echo codex ;;
      show-options) echo worker ;;
      load-buffer)
        cat >/dev/null
        if [ "$stage" = buffer-load ]; then printf '999:1:300\n' >"$state"; fi ;;
      paste-buffer)
        if [ "$stage" = after-paste ]; then printf '999:1:300\n' >"$state"; fi ;;
    esac
  }
  pane_box_ready() {
    if [ "$stage" = readiness ]; then printf '999:1:300\n' >"$state"; fi
    return 0
  }
  pane_box_text() { printf message; }
  pane_takes_keys() { return 0; }
  if cmd_send %1 message >"$TEST_DIR/identity-$stage.out" 2>&1; then
    fail "send accepted a changed agent during $stage"
  fi
  assert_contains "$TEST_DIR/identity-$stage.out" 'agent changed'
  assert_not_contains "$log" 'send-keys'
  if [ "$stage" = after-paste ]; then assert_contains "$log" 'paste-buffer'
  else assert_not_contains "$log" 'paste-buffer'; fi
  assert_contains "$log" 'load-buffer'
)
for identity_stage in readiness buffer-load after-paste; do
  test_changed_agent_identity "$identity_stage"
done
echo 'delivery lock tests: PASS'
