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
  rev-parse) exit 0 ;;
  rev-list) if [ -f "$WEB_UPDATE_DONE" ]; then echo 0; else echo 2; fi ;;
  pull)
    if [ "${WEB_UPDATE_FAIL:-0}" = 1 ]; then echo 'pull refused' >&2; exit 1; fi
    touch "$WEB_UPDATE_DONE" ;;
  fetch) exit 0 ;;
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
assert_contains "$TEST_DIR/web-update.out" '{"update":2,"host":"'
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
echo 'web_update: PASS'
