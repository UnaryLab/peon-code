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
if [ "${1:-}" = -V ]; then printf 'tmux 3.4\n'; exit 0; fi
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

strict_bin="$TEST_DIR/web-strict-bin"
old_bin="$TEST_DIR/web-old-tmux-bin"
mkdir -p "$strict_bin" "$old_bin" "$TEST_DIR/web-home"
for command in bash dirname readlink; do
  ln -s "$(command -v "$command")" "$strict_bin/$command"
done
ln -s "$ROOT/peon-code-web.sh" "$strict_bin/peon-code-web"
cat > "$strict_bin/python3" <<'FAKE'
#!/usr/bin/env bash
[ "${1:-}" != -c ] || exit 0
printf '%s\n' "$@" > "$WEB_TEST_LOG"
FAKE
cat > "$old_bin/tmux" <<'FAKE'
#!/usr/bin/env bash
printf 'tmux 3.1\n'
FAKE
chmod +x "$strict_bin/python3" "$old_bin/tmux"
for test_path in "$strict_bin" "$old_bin:$strict_bin"; do
  for ssh_style in separate equals; do
    if [ "$ssh_style" = separate ]; then
      set -- 'team with spaces' --ssh 'remote host' --no-open
    else
      set -- 'team with spaces' '--ssh=remote host' --no-open
    fi
    PATH="$test_path" HOME="$TEST_DIR/web-home" WEB_TEST_LOG="$TEST_DIR/web-ssh.log" \
      "$strict_bin/peon-code-web" "$@"
    printf '%s\n' "$ROOT/web/server.py" "$@" > "$TEST_DIR/web-ssh.expected"
    cmp -s "$TEST_DIR/web-ssh.expected" "$TEST_DIR/web-ssh.log" || fail 'SSH launch changed server arguments'
  done
  for mode in --stdio 'team with spaces'; do
    rc=0
    PATH="$test_path" HOME="$TEST_DIR/web-home" WEB_TEST_LOG="$TEST_DIR/web-refused.log" \
      "$strict_bin/peon-code-web" "$mode" \
      >"$TEST_DIR/web-tmux.out" 2>"$TEST_DIR/web-tmux.err" || rc=$?
    [ "$rc" -eq 1 ] || fail "web $mode launch returned $rc instead of 1"
    if [ "$test_path" = "$strict_bin" ]; then found='not installed'; else found='tmux 3.1'; fi
    assert_contains "$TEST_DIR/web-tmux.err" "peon-code: tmux 3.2 or newer is required (found $found)"
    [ ! -e "$TEST_DIR/web-refused.log" ] || fail 'tmux refusal launched the Python server'
  done
done
echo 'web_launcher: PASS'
