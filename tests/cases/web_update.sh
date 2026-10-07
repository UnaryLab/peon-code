#!/usr/bin/env bash
set -euo pipefail
CASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/helpers.sh
. "$CASE_DIR/../helpers.sh"
bin_dir="$TEST_DIR/web-update-bin"
mkdir -p "$bin_dir"
cat > "$bin_dir/git" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WEB_UPDATE_LOG"
case "$3" in
  rev-parse)
    case "$*" in
      *--symbolic-full-name*) echo refs/remotes/origin/main ;;
      *) echo 1111111111111111111111111111111111111111 ;;
    esac ;;
  symbolic-ref) echo main ;;
  config)
    case "$5" in
      *.remote) echo origin ;;
      *) echo refs/heads/main ;;
    esac ;;
  ls-remote)
    if [ "${WEB_UPDATE_PUBLIC_FAIL:-0}" = 1 ] && [ "$5" != origin ]; then exit 1; fi
    if [ -f "$WEB_UPDATE_DONE" ]; then
      printf '1111111111111111111111111111111111111111\trefs/heads/main\n'
    else
      printf '2222222222222222222222222222222222222222\trefs/heads/main\n'
    fi ;;
  merge-base|cat-file) exit 1 ;;
  pull)
    if [ "${WEB_UPDATE_FAIL:-0}" = 1 ]; then echo 'pull refused' >&2; exit 1; fi
    touch "$WEB_UPDATE_DONE" ;;
  update-ref)
    [ "${WEB_UPDATE_REF_FAIL:-0}" != 1 ] || { echo 'tracking ref refused' >&2; exit 1; } ;;
esac
FAKE
cat > "$bin_dir/python3" <<'FAKE'
#!/usr/bin/env bash
printf 'python:%s\n' "$*" >> "$WEB_UPDATE_LOG"
FAKE
chmod +x "$bin_dir/git" "$bin_dir/python3"
run_web_update() {
  PATH="$bin_dir:$PATH" PEON_UPDATE_PAUSE=0 WEB_UPDATE_LOG="$TEST_DIR/web-update.log" \
    WEB_UPDATE_DONE="$TEST_DIR/web-update.done" WEB_UPDATE_FAIL="${WEB_UPDATE_FAIL:-0}" \
    "$ROOT/peon-code-web.sh" "$@"
}
# A normal nonTTY launch defaults no even with a piped yes.
printf 'y\n' | run_web_update --port 9123 >"$TEST_DIR/web-update.out" 2>"$TEST_DIR/web-update.err"
assert_not_contains "$TEST_DIR/web-update.log" 'pull -q --ff-only'
assert_contains "$TEST_DIR/web-update.log" 'python:'
# SSH protocol asks once, accepts explicitly, and restarts with all arguments.
: >"$TEST_DIR/web-update.log"
printf 'y\n' | run_web_update --stdio --no-open --port 9123 >"$TEST_DIR/web-update.out" 2>"$TEST_DIR/web-update.err"
assert_contains "$TEST_DIR/web-update.out" '{"update":1,"host":"'
assert_contains "$TEST_DIR/web-update.log" 'pull -q --ff-only'
assert_contains "$TEST_DIR/web-update.log" '--stdio --no-open --port 9123'
# Decline and a failed pull both continue to the current UI without a restart loop.
rm "$TEST_DIR/web-update.done"
: >"$TEST_DIR/web-update.log"
printf 'n\n' | run_web_update --stdio >"$TEST_DIR/web-update.out" 2>"$TEST_DIR/web-update.err"
assert_not_contains "$TEST_DIR/web-update.log" 'pull -q --ff-only'
assert_contains "$TEST_DIR/web-update.log" 'python:'
: >"$TEST_DIR/web-update.log"
printf 'y\n' | WEB_UPDATE_FAIL=1 run_web_update --stdio >"$TEST_DIR/web-update.out" 2>"$TEST_DIR/web-update.err"
assert_contains "$TEST_DIR/web-update.err" 'pull refused'
assert_contains "$TEST_DIR/web-update.err" 'update failed on'
[ "$(grep -c 'pull -q --ff-only' "$TEST_DIR/web-update.log")" = 1 ] || fail 'failed pull retried'
assert_contains "$TEST_DIR/web-update.log" 'python:'
: >"$TEST_DIR/web-update.log"
printf 'y\n' | WEB_UPDATE_PUBLIC_FAIL=1 WEB_UPDATE_REF_FAIL=1 run_web_update --stdio >"$TEST_DIR/web-update.out" 2>"$TEST_DIR/web-update.err"
assert_contains "$TEST_DIR/web-update.err" 'tracking ref update failed on'
[ "$(grep -c 'pull -q --ff-only' "$TEST_DIR/web-update.log")" = 1 ] || fail 'tracking ref failure retried the pull'
assert_contains "$TEST_DIR/web-update.log" 'python:'
echo 'web_update: PASS'
