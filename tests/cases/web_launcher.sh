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
echo 'web_launcher: PASS'
