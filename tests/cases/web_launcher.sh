#!/usr/bin/env bash
set -euo pipefail
CASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/helpers.sh
. "$CASE_DIR/../helpers.sh"
bin_dir="$TEST_DIR/web-bin"
mkdir -p "$bin_dir"
cat > "$bin_dir/python3" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$WEB_TEST_LOG"
FAKE
cat > "$bin_dir/tmux" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
chmod +x "$bin_dir/python3" "$bin_dir/tmux"
ln -s "$ROOT/peon-code-web.sh" "$bin_dir/peon-code-web"
PATH="$bin_dir:$PATH" WEB_TEST_LOG="$TEST_DIR/web-launch.log" "$bin_dir/peon-code-web" 'team with spaces' --no-open
assert_contains "$TEST_DIR/web-launch.log" "$ROOT/web/server.py"
assert_contains "$TEST_DIR/web-launch.log" 'team with spaces'
assert_contains "$TEST_DIR/web-launch.log" '--no-open'
cat > "$bin_dir/python3" <<'FAKE'
#!/usr/bin/env bash
case ${1:-} in
  --version) printf 'Python 3.9.21\n' ;;
  -c)
    if [ "${2:-}" = 'import sys; sys.exit(sys.version_info < (3, 10))' ]; then exit 1; fi ;;
esac
FAKE
rc=0
PATH="$bin_dir:$PATH" "$bin_dir/peon-code-web" --help \
  >"$TEST_DIR/web-old-python.out" 2>"$TEST_DIR/web-old-python.err" || rc=$?
[ "$rc" -eq 1 ] || fail "Python 3.9 launch returned $rc instead of 1"
[ "$(cat "$TEST_DIR/web-old-python.err")" = 'peon-code-web requires Python 3.10 or newer (found Python 3.9.21)' ] ||
  fail 'Python 3.9 launch did not report the exact version error'
echo 'web_launcher: PASS'
