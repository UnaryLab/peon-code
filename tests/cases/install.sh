#!/usr/bin/env bash
set -euo pipefail
CASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/helpers.sh
. "$CASE_DIR/../helpers.sh"

test_install_guard() {
  local home_dir="$TEST_DIR/home-install" bin_dir="$TEST_DIR/bin-install"
  mkdir -p "$home_dir" "$bin_dir"
  printf 'keep me\n' >"$bin_dir/peon-code"
  if HOME="$home_dir" "$ROOT/install.sh" "$bin_dir" >"$TEST_DIR/install.out" 2>"$TEST_DIR/install.err"; then
    fail "install replaced an existing command"
  fi
  [ "$(cat "$bin_dir/peon-code")" = "keep me" ] || fail "install changed an existing command"

  bin_dir="$TEST_DIR/bin-dangling"
  mkdir -p "$bin_dir"
  ln -s "$TEST_DIR/missing-foreign-command" "$bin_dir/peon-code"
  if HOME="$home_dir" "$ROOT/install.sh" "$bin_dir" >"$TEST_DIR/install-dangling.out" 2>"$TEST_DIR/install-dangling.err"; then
    fail "install replaced a foreign dangling symlink"
  fi
  [ "$(readlink "$bin_dir/peon-code")" = "$TEST_DIR/missing-foreign-command" ] ||
    fail "install changed a foreign dangling symlink"

  bin_dir="$TEST_DIR/bin-new"
  mkdir -p "$bin_dir"
  HOME="$home_dir" "$ROOT/install.sh" "$bin_dir" >"$TEST_DIR/install-new.out"
  HOME="$home_dir" "$ROOT/install.sh" "$bin_dir" >"$TEST_DIR/install-again.out"
  [ "$(readlink "$bin_dir/peon-code")" = "$ROOT/peon-code.sh" ] ||
    fail "install did not create the expected symlink"
  [ "$(readlink "$bin_dir/peon-code-web")" = "$ROOT/peon-code-web.sh" ] ||
    fail "install did not create the web command symlink"
  (
    cd "$TEST_DIR"
    HOME="$home_dir" "$bin_dir/peon-code" -h
  ) >"$TEST_DIR/installed-help.out"
  assert_contains "$TEST_DIR/installed-help.out" "peon-code.sh [-c file]"
  "$bin_dir/peon-code" uninstall "$bin_dir" >"$TEST_DIR/uninstall.out"
  [ ! -L "$bin_dir/peon-code-web" ] || fail "uninstall left the web symlink"
  [ ! -L "$bin_dir/peon-code" ] || fail "uninstall left the terminal symlink"

  bin_dir="$TEST_DIR/bin-web-foreign"
  mkdir -p "$bin_dir"
  printf 'keep web command\n' >"$bin_dir/peon-code-web"
  if HOME="$home_dir" "$ROOT/install.sh" "$bin_dir" >"$TEST_DIR/install-web.out" 2>&1; then
    fail "install replaced an existing web command"
  fi
  [ ! -e "$bin_dir/peon-code" ] || fail "install created a partial installation"
  [ "$(cat "$bin_dir/peon-code-web")" = 'keep web command' ] || fail "install changed a foreign web command"
  ln -s "$ROOT/peon-code.sh" "$bin_dir/peon-code"
  if "$bin_dir/peon-code" uninstall "$bin_dir" >"$TEST_DIR/uninstall-web.out" 2>&1; then
    fail "uninstall accepted a foreign web command"
  fi
  [ -L "$bin_dir/peon-code" ] || fail "uninstall removed a command before validating both links"
  [ "$(cat "$bin_dir/peon-code-web")" = 'keep web command' ] || fail "uninstall changed a foreign web command"
}

test_install_tmux_conf() {
  local home_dir="$TEST_DIR/home-tmuxconf" bin_dir="$TEST_DIR/bin-tmuxconf"
  mkdir -p "$home_dir" "$bin_dir"

  # Fresh home: the config is installed.
  HOME="$home_dir" "$ROOT/install.sh" "$bin_dir" >"$TEST_DIR/tmuxconf-new.out"
  [ "$(cat "$home_dir/.tmux.conf")" = "$(cat "$ROOT/tmux.conf")" ] ||
    fail "install did not write ~/.tmux.conf"

  # Existing config, non-interactive: left untouched.
  printf 'my own config\n' >"$home_dir/.tmux.conf"
  HOME="$home_dir" "$ROOT/install.sh" "$bin_dir" >"$TEST_DIR/tmuxconf-keep.out" </dev/null
  [ "$(cat "$home_dir/.tmux.conf")" = "my own config" ] ||
    fail "install overwrote an existing ~/.tmux.conf"
}

# The start path offers a pull when the checkout is behind upstream, from the
# refs the last fetch left; no (or headless stdin) leaves it alone, yes pulls.
test_update_offer() {
  local origin="$TEST_DIR/update-origin" mine="$TEST_DIR/update-mine"
  git init -q "$origin"
  git -C "$origin" -c user.name=t -c user.email=t@t commit -q --allow-empty -m one
  git clone -q "$origin" "$mine"
  git -C "$origin" -c user.name=t -c user.email=t@t commit -q --allow-empty -m two

  offer() { PEON_UPDATE_PAUSE=0 bash -c 'SCRIPT_DIR=$1; source "$2/lib/config.sh"; offer_update' _ "$mine" "$ROOT"; }
  if offer </dev/null 2>"$TEST_DIR/update-before.err"; then fail "offered a pull before any fetch"; fi
  assert_not_contains "$TEST_DIR/update-before.err" "pull now"
  # That call's background fetch brings the new commit in; wait for it.
  local tries=0
  until [ "$(git -C "$mine" rev-parse '@{u}')" = "$(git -C "$origin" rev-parse HEAD)" ]; do
    [ $((tries += 1)) -le 20 ] || fail "the background fetch never landed"
    sleep 1
  done
  if offer </dev/null 2>"$TEST_DIR/update-headless.err"; then fail "headless stdin counted as yes"; fi
  assert_contains "$TEST_DIR/update-headless.err" "peon-code: 1 new commit(s) upstream; pull now? [y/N] "
  assert_contains "$TEST_DIR/update-headless.err" "not updated; later: git -C $mine pull"
  if echo n | offer 2>"$TEST_DIR/update-no.err"; then fail "n counted as yes"; fi
  [ "$(git -C "$mine" rev-parse HEAD)" != "$(git -C "$origin" rev-parse HEAD)" ] || fail "n pulled anyway"
  echo y | offer 2>"$TEST_DIR/update-yes.err" || fail "y did not report a pull"
  [ "$(git -C "$mine" rev-parse HEAD)" = "$(git -C "$origin" rev-parse HEAD)" ] || fail "y did not pull"
  assert_contains "$TEST_DIR/update-yes.err" "peon-code: updated; starting"
  if offer </dev/null 2>"$TEST_DIR/update-current.err"; then fail "offered a pull when current"; fi
  assert_not_contains "$TEST_DIR/update-current.err" "pull now"
}

fake_bin=$(make_fake_commands)
test_install_guard
test_install_tmux_conf
test_update_offer
echo "install: PASS"
