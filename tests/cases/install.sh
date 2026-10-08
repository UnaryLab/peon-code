#!/usr/bin/env bash
set -euo pipefail
CASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/helpers.sh
. "$CASE_DIR/../helpers.sh"

test_install_dependencies() {
  local tools="$TEST_DIR/dependency-tools" template="$TEST_DIR/dependency-tmux" tool version index=0
  local home_dir bin_dir out="$TEST_DIR/dependency.out" err="$TEST_DIR/dependency.err" manager manager_bin python_command install_command status option
  mkdir -p "$tools"
  for tool in bash dirname mkdir ln cp readlink cat rm; do
    ln -s "$(command -v "$tool")" "$tools/$tool"
  done
  cat >"$template" <<'FAKE_VERSION'
#!/usr/bin/env bash
printf '%s\n' "${INSTALL_TMUX_VERSION:-tmux 3.4}"
FAKE_VERSION
  chmod +x "$template"
  cp "$template" "$tools/tmux"
  for version in 'tmux 3.1' 'tmux invalid'; do
    index=$((index + 1)); home_dir="$TEST_DIR/dependency-home-$index"; bin_dir="$home_dir/bin"
    mkdir -p "$home_dir"
    if PATH="$tools" HOME="$home_dir" INSTALL_TMUX_VERSION="$version" "$ROOT/install.sh" "$bin_dir" >"$out" 2>"$err" </dev/null; then
      fail "install accepted $version"
    fi
    assert_contains "$err" 'tmux 3.2 or newer is required'
    [ "$(wc -l <"$err")" -eq 1 ] || fail 'bad tmux version produced more than one error line'
    [[ ! -e "$bin_dir" && ! -e "$home_dir/.config" && ! -e "$home_dir/.tmux.conf" ]] || fail 'tmux refusal installed files'
  done
  PATH="$tools" HOME="$home_dir" INSTALL_TMUX_VERSION='tmux 3.1' "$ROOT/peon-code.sh" -h >"$out" 2>"$err" || fail 'help required current tmux'
  if PATH="$tools" HOME="$home_dir" INSTALL_TMUX_VERSION='tmux 3.1' "$ROOT/peon-code.sh" team >"$out" 2>"$err"; then
    fail 'terminal launcher accepted old tmux'
  fi
  assert_contains "$err" 'tmux 3.2 or newer is required'
  for version in 'tmux 3.2' 'tmux 3.4' 'tmux 3.3a' 'tmux next-3.5' 'tmux 3.5-rc'; do
    index=$((index + 1)); home_dir="$TEST_DIR/dependency-home-$index"; bin_dir="$home_dir/bin"
    mkdir -p "$home_dir"
    PATH="$tools" HOME="$home_dir" INSTALL_TMUX_VERSION="$version" "$ROOT/install.sh" "$bin_dir" >"$out" 2>"$err" </dev/null || fail "install refused $version"
    [[ -L "$bin_dir/peon-code" && -L "$bin_dir/peon-code-web" ]] || fail 'install did not link both commands'
    [ -f "$home_dir/.config/peon-code/peon-code.conf" ] || fail 'install did not seed config'
    assert_contains "$out" 'note: python3 3.10+ not found; peon-code-web will not run'
    assert_contains "$out" 'note: no agent CLI found (claude, codex, copilot); install one before launching'
    assert_contains "$out" 'npm install -g @anthropic-ai/claude-code'
    assert_contains "$out" 'npm install -g @openai/codex'
    assert_contains "$out" 'npm install -g @github/copilot'
  done
  rm -f "$tools/tmux"
  home_dir="$TEST_DIR/dependency-home-missing"; mkdir -p "$home_dir"
  if PATH="$tools" HOME="$home_dir" PEON_INSTALL_ASSUME_YES=0 "$ROOT/install.sh" "$home_dir/bin" >"$out" 2>"$err" </dev/null; then fail 'install accepted missing tmux'; fi
  [ "$(cat "$err")" = 'install tmux 3.2+ with your package manager' ] || fail 'missing tmux did not print manual install hint'
  [[ ! -e "$home_dir/bin" && ! -e "$home_dir/.config" ]] || fail 'missing tmux installed files'
  for option in -h --help; do
    PATH="$tools" HOME="$home_dir" "$ROOT/peon-code.sh" "$option" >"$out" 2>"$err" || fail 'help required installed tmux'
    assert_contains "$out" 'peon-code.sh [-c file]'
  done
  bin_dir="$home_dir/bin"
  mkdir -p "$bin_dir"
  ln -s "$ROOT/peon-code.sh" "$bin_dir/peon-code"
  ln -s "$ROOT/peon-code-web.sh" "$bin_dir/peon-code-web"
  PATH="$tools" HOME="$home_dir" "$bin_dir/peon-code" uninstall "$bin_dir" >"$out" 2>"$err" || fail 'uninstall required installed tmux'
  [[ ! -L "$bin_dir/peon-code" && ! -L "$bin_dir/peon-code-web" ]] || fail 'uninstall without tmux left command links'

  for manager in brew apt-get dnf pacman; do
    manager_bin="$TEST_DIR/dependency-$manager"; home_dir="$TEST_DIR/dependency-home-$manager"
    mkdir -p "$manager_bin" "$home_dir"
    for tool in bash dirname mkdir ln cp readlink cat; do ln -s "$tools/$tool" "$manager_bin/$tool"; done
    cat >"$manager_bin/$manager" <<'FAKE_MANAGER'
#!/usr/bin/env bash
printf '%s %s\n' "${0##*/}" "$*" >>"$INSTALL_MANAGER_LOG"
[ "${INSTALL_MANAGER_FAIL:-0}" = 0 ] || exit 1
cp "$INSTALL_TMUX_TEMPLATE" "$INSTALL_TOOL_BIN/tmux"
FAKE_MANAGER
    cat >"$manager_bin/sudo" <<'FAKE_SUDO'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >>"$INSTALL_MANAGER_LOG"
exec "$@"
FAKE_SUDO
    chmod +x "$manager_bin/$manager" "$manager_bin/sudo"
    case $manager in
      brew) install_command='brew install tmux'; python_command='brew install python' ;;
      apt-get) install_command='sudo apt-get install -y tmux'; python_command='sudo apt-get install -y python3' ;;
      dnf) install_command='sudo dnf install -y tmux'; python_command='sudo dnf install -y python3' ;;
      pacman) install_command='sudo pacman -S --noconfirm tmux'; python_command='sudo pacman -S --noconfirm python' ;;
    esac
    if printf 'y\n' | PATH="$manager_bin" HOME="$home_dir" PEON_INSTALL_ASSUME_YES=0 INSTALL_MANAGER_LOG="$TEST_DIR/dependency-manager-$manager.log" "$ROOT/install.sh" "$home_dir/bin" >"$out" 2>"$err"; then fail 'piped yes counted as a TTY approval'; fi
    [ "$(cat "$err")" = "$install_command" ] || fail 'declined install did not print the package command'
    [ ! -e "$TEST_DIR/dependency-manager-$manager.log" ] || fail 'piped yes ran the package manager'
    [[ ! -e "$home_dir/bin" && ! -e "$home_dir/.config" ]] || fail 'declined install wrote files'
    if PATH="$manager_bin" HOME="$home_dir" PEON_INSTALL_ASSUME_YES=1 INSTALL_MANAGER_FAIL=1 INSTALL_MANAGER_LOG="$TEST_DIR/dependency-manager-$manager.log" \
      "$ROOT/install.sh" "$home_dir/bin" >"$out" 2>"$err" </dev/null; then fail 'failed package install succeeded'; fi
    [[ ! -e "$home_dir/bin" && ! -e "$home_dir/.config" ]] || fail 'failed package install wrote files'
    if [ "$manager" = brew ]; then
      if PATH="$manager_bin" HOME="$home_dir" PEON_INSTALL_ASSUME_YES=1 INSTALL_TMUX_VERSION='tmux 3.1' INSTALL_MANAGER_LOG="$TEST_DIR/dependency-manager-$manager.log" \
        INSTALL_TMUX_TEMPLATE="$template" INSTALL_TOOL_BIN="$manager_bin" "$ROOT/install.sh" "$home_dir/bin" >"$out" 2>"$err" </dev/null; then fail 'install accepted an old tmux from the package manager'; fi
      assert_contains "$err" 'tmux 3.2 or newer is required'
      [[ ! -e "$home_dir/bin" && ! -e "$home_dir/.config" ]] || fail 'old package-manager tmux installed files'
      rm -f "$manager_bin/tmux"
    fi
    PATH="$manager_bin" HOME="$home_dir" PEON_INSTALL_ASSUME_YES=1 INSTALL_MANAGER_LOG="$TEST_DIR/dependency-manager-$manager.log" \
      INSTALL_TMUX_TEMPLATE="$template" INSTALL_TOOL_BIN="$manager_bin" "$ROOT/install.sh" "$home_dir/bin" >"$out" 2>"$err" </dev/null || fail "fake $manager install failed"
    [[ -L "$home_dir/bin/peon-code" && -L "$home_dir/bin/peon-code-web" ]] || fail 'approved fake install did not link both commands'
    assert_contains "$out" "$python_command"
    case $manager in
      brew) assert_contains "$TEST_DIR/dependency-manager-$manager.log" 'brew install tmux' ;;
      apt-get|dnf) assert_contains "$TEST_DIR/dependency-manager-$manager.log" "sudo $manager install -y tmux" ;;
      pacman) assert_contains "$TEST_DIR/dependency-manager-$manager.log" 'sudo pacman -S --noconfirm tmux' ;;
    esac
    assert_not_contains "$TEST_DIR/dependency-manager-$manager.log" 'python'
    assert_not_contains "$TEST_DIR/dependency-manager-$manager.log" 'npm'
  done
  cp "$template" "$tools/tmux"
  cat >"$tools/python3" <<'FAKE_PYTHON'
#!/usr/bin/env bash
[ "$*" = '-c import sys; sys.exit(sys.version_info < (3, 10))' ] || exit 2
exit "${INSTALL_PYTHON_EXIT:-0}"
FAKE_PYTHON
  chmod +x "$tools/python3"
  ln -s "$tools/bash" "$tools/codex"
  for status in 0 1 2; do
    home_dir="$TEST_DIR/dependency-python-$status"; mkdir -p "$home_dir"
    PATH="$tools" HOME="$home_dir" INSTALL_PYTHON_EXIT="$status" "$ROOT/install.sh" "$home_dir/bin" >"$out" 2>"$err" </dev/null || fail 'optional Python failure stopped install'
    assert_not_contains "$out" 'note: no agent CLI found'
    if [ "$status" = 0 ]; then assert_not_contains "$out" 'note: python3 3.10+ not found'; else assert_contains "$out" 'note: python3 3.10+ not found; peon-code-web will not run'; fi
  done
}

test_install_guard() {
  local home_dir="$TEST_DIR/home-install" bin_dir="$TEST_DIR/bin-install"
  local PATH="$fake_bin:$PATH"
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
  local PATH="$fake_bin:$PATH"
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

test_install_git_hooks() {
  local repo="$TEST_DIR/install-repo" home_dir="$TEST_DIR/install-repo-home" bin_dir="$TEST_DIR/install-repo-bin"
  local nested="$repo/archive" alias_dir="$TEST_DIR/install-repo-link" hooks_path
  mkdir -p "$repo/lib" "$home_dir"
  cp "$ROOT/install.sh" "$ROOT/tmux.conf" "$ROOT/peon-code.conf.example" "$repo/"
  cp "$ROOT/lib/deps.sh" "$repo/lib/"
  git init -q -b main "$repo"
  HOME="$home_dir" "$repo/install.sh" "$bin_dir" >"$TEST_DIR/install-hooks.out" </dev/null
  [ "$(git -C "$repo" config --get core.hooksPath)" = .githooks ] || fail 'install did not set the hook path'
  assert_contains "$TEST_DIR/install-hooks.out" 'installed Git hooks: .githooks'
  for hooks_path in .githooks '' custom-hooks; do
    git -C "$repo" config core.hooksPath "$hooks_path"
    cp "$repo/.git/config" "$TEST_DIR/install-parent-config"
    HOME="$home_dir" "$repo/install.sh" "$bin_dir" >"$TEST_DIR/install-hooks.out" </dev/null
    cmp "$repo/.git/config" "$TEST_DIR/install-parent-config" || fail 'install changed an existing hook path'
    assert_contains "$TEST_DIR/install-hooks.out" "kept Git hooks: $hooks_path"
  done
  ln -s "$repo" "$alias_dir"
  HOME="$home_dir" "$alias_dir/install.sh" "$TEST_DIR/install-symlink-bin" >"$TEST_DIR/install-symlink.out" </dev/null
  cmp "$repo/.git/config" "$TEST_DIR/install-parent-config" || fail 'symlink install changed an existing hook path'
  assert_contains "$TEST_DIR/install-symlink.out" 'kept Git hooks: custom-hooks'
  mkdir -p "$nested"
  cp "$repo/install.sh" "$repo/tmux.conf" "$repo/peon-code.conf.example" "$nested/"
  cp -R "$repo/lib" "$nested/"
  HOME="$home_dir" "$nested/install.sh" "$TEST_DIR/install-nested-bin" >"$TEST_DIR/install-nested.out" </dev/null
  cmp "$repo/.git/config" "$TEST_DIR/install-parent-config" || fail 'nested install changed its parent Git config'
  assert_not_contains "$TEST_DIR/install-nested.out" 'Git hooks:'
}

# The public check offers on the first start and leaves cached refs alone.
test_update_offer() {
  local origin="$TEST_DIR/update-origin" source="$TEST_DIR/update-source" mine="$TEST_DIR/update-mine" cached
  git init -q -b main "$source"
  git -C "$source" -c user.name=t -c user.email=t@t commit -q --allow-empty -m one
  git clone -q --bare "$source" "$origin"
  git clone -q "$origin" "$mine"
  git -C "$source" -c user.name=t -c user.email=t@t commit -q --allow-empty -m two
  git -C "$source" push -q "$origin" main
  cached=$(git -C "$mine" rev-parse '@{u}')

  offer() { PEON_UPDATE_URL="$origin" PEON_UPDATE_PAUSE=0 bash -c 'SCRIPT_DIR=$1; source "$2/lib/config.sh"; offer_update' _ "$mine" "$ROOT"; }
  if offer </dev/null 2>"$TEST_DIR/update-headless.err"; then fail "headless stdin counted as yes"; fi
  assert_contains "$TEST_DIR/update-headless.err" "peon-code: update available upstream; pull now? [y/N] "
  assert_contains "$TEST_DIR/update-headless.err" "not updated; later: git -C $mine pull"
  [ "$(git -C "$mine" rev-parse '@{u}')" = "$cached" ] || fail "the check wrote cached refs"
  [ ! -f "$mine/.git/FETCH_HEAD" ] || fail "the check fetched objects"
  if echo n | offer 2>"$TEST_DIR/update-no.err"; then fail "n counted as yes"; fi
  [ "$(git -C "$mine" rev-parse HEAD)" != "$(git -C "$origin" rev-parse HEAD)" ] || fail "n pulled anyway"
  echo y | offer 2>"$TEST_DIR/update-yes.err" || fail "y did not report a pull"
  [ "$(git -C "$mine" rev-parse HEAD)" = "$(git -C "$origin" rev-parse HEAD)" ] || fail "y did not pull"
  [ "$(git -C "$mine" rev-parse '@{u}')" = "$cached" ] || fail "a public pull changed the clone's tracking ref"
  assert_contains "$TEST_DIR/update-yes.err" "peon-code: updated; starting"
  if offer </dev/null 2>"$TEST_DIR/update-current.err"; then fail "offered a pull when current"; fi
  assert_not_contains "$TEST_DIR/update-current.err" "pull now"
  git -C "$source" -c user.name=t -c user.email=t@t commit -q --allow-empty -m fallback
  git -C "$source" push -q "$origin" main
  PEON_UPDATE_URL="$TEST_DIR/missing-public" PEON_UPDATE_PAUSE=0 \
    bash -c 'SCRIPT_DIR=$1; source "$2/lib/config.sh"; offer_update' _ "$mine" "$ROOT" \
    >"$TEST_DIR/update-real-fallback.out" 2>"$TEST_DIR/update-real-fallback.err" <<<'y'
  [ "$(git -C "$mine" rev-parse HEAD)" = "$(git -C "$origin" rev-parse HEAD)" ] || fail "fallback did not pull"
  [ "$(git -C "$mine" rev-parse '@{u}')" = "$(git -C "$mine" rev-parse HEAD)" ] || fail "fallback left the tracking ref stale"
  assert_contains "$TEST_DIR/update-real-fallback.err" "trying origin"
  git -C "$mine" -c user.name=t -c user.email=t@t commit -q --allow-empty -m local
  if offer </dev/null 2>"$TEST_DIR/update-ahead.err"; then fail "offered an update already in local history"; fi
  assert_not_contains "$TEST_DIR/update-ahead.err" "pull now"
  git -C "$source" -c user.name=t -c user.email=t@t commit -q --allow-empty -m remote
  git -C "$source" push -q "$origin" main
  git -C "$mine" fetch -q "$origin" main
  if offer </dev/null 2>"$TEST_DIR/update-diverged.err"; then fail "offered an update for known diverged history"; fi
  assert_not_contains "$TEST_DIR/update-diverged.err" "pull now"
}

test_public_pull_keeps_fork_tracking() {
  local source="$TEST_DIR/fork-source" fork="$TEST_DIR/fork-origin" public="$TEST_DIR/fork-public" mine="$TEST_DIR/fork-mine" cached
  git init -q -b main "$source"
  git -C "$source" -c user.name=t -c user.email=t@t commit -q --allow-empty -m one
  git clone -q --bare "$source" "$fork"
  git clone -q "$fork" "$mine"
  cached=$(git -C "$fork" rev-parse HEAD)
  git -C "$source" -c user.name=t -c user.email=t@t commit -q --allow-empty -m public
  git clone -q --bare "$source" "$public"
  PEON_UPDATE_URL="$public" PEON_UPDATE_PAUSE=0 bash -c 'SCRIPT_DIR=$1; source "$2/lib/config.sh"; offer_update' _ "$mine" "$ROOT" \
    >"$TEST_DIR/fork-update.out" 2>"$TEST_DIR/fork-update.err" <<<'y'
  [ "$(git -C "$mine" rev-parse HEAD)" = "$(git -C "$public" rev-parse HEAD)" ] || fail "the public update did not reach the fork clone"
  [ "$(git -C "$mine" rev-parse '@{u}')" = "$cached" ] || fail "the public update replaced the fork's tracking tip"
  [ "$(git -C "$fork" rev-parse HEAD)" = "$cached" ] || fail "the public update changed the fork"
}

test_update_probe_timeout() {
  local bin_dir="$TEST_DIR/update-timeout-bin" started=$SECONDS mode
  mkdir -p "$bin_dir" "$TEST_DIR/update-tmp"
  cp "$fake_bin/tmux" "$bin_dir/tmux"
  cat >"$bin_dir/git" <<'FAKE_GIT'
#!/usr/bin/env bash
if [ -n "${PROBE_ENV_LOG:-}" ]; then
  printf '%s|%s\n' "$3" "${GIT_TERMINAL_PROMPT:-unset}" >>"$PROBE_ENV_LOG"
fi
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
    printf '%s\n' "$$" >"$PROBE_PID_FILE"
    echo probe-error >&2
    mode=${PROBE_MODE:-}
    [ "$5" != origin ] || mode=${PROBE_FALLBACK_MODE:-$mode}
    [ "$mode" != empty ] || exit 0
    printf '2222222222222222222222222222222222222222\trefs/heads/main\n'
    case $mode in
      fail) exit 1 ;;
      hang) exec sleep 30 ;;
      ignore) trap '' TERM; while :; do sleep 0.1; done ;;
    esac ;;
  merge-base|cat-file) exit 1 ;;
  pull)
    [ -z "${PROBE_PULL_SOURCE:-}" ] || printf '%s\n' "$6" >"$PROBE_PULL_SOURCE" ;;
esac
FAKE_GIT
  chmod +x "$bin_dir/git"
  PATH="$bin_dir:$PATH" PEON_FETCH_TIMEOUT=01 PROBE_MODE=hang PROBE_PID_FILE="$TEST_DIR/probe.pid" \
    TMPDIR="$TEST_DIR/update-tmp" FAKE_TMUX_LOG="$TEST_DIR/update-timeout.log" FAKE_TMUX_MODE=owned \
    "$ROOT/peon-code.sh" update-check codex >"$TEST_DIR/update-timeout.out" 2>"$TEST_DIR/update-timeout.err" </dev/null
  [ $((SECONDS - started)) -le 3 ] || fail "a hanging public check delayed startup"
  assert_contains "$TEST_DIR/update-timeout.out" "session update-check is ready"
  assert_not_contains "$TEST_DIR/update-timeout.out" "2222222222222222222222222222222222222222"
  [ -s "$TEST_DIR/probe.pid" ] || fail "the update check did not probe"
  if kill -0 "$(cat "$TEST_DIR/probe.pid")" 2>/dev/null; then fail "the timed-out probe is still running"; fi
  assert_contains "$TEST_DIR/update-timeout.err" "trying origin"
  assert_contains "$TEST_DIR/update-timeout.err" "starting current version"
  assert_not_contains "$TEST_DIR/update-timeout.err" "pull now"
  started=$SECONDS
  PATH="$bin_dir:$PATH" PEON_FETCH_TIMEOUT=1 PROBE_MODE=ignore PROBE_PID_FILE="$TEST_DIR/probe.pid" \
    TMPDIR="$TEST_DIR/update-tmp" FAKE_TMUX_LOG="$TEST_DIR/update-ignore.log" FAKE_TMUX_MODE=owned \
    "$ROOT/peon-code.sh" update-ignore codex >"$TEST_DIR/update-ignore.out" 2>"$TEST_DIR/update-ignore.err" </dev/null
  [ $((SECONDS - started)) -le 6 ] || fail "TERM-ignoring probes blocked startup"
  assert_contains "$TEST_DIR/update-ignore.out" "session update-ignore is ready"
  assert_contains "$TEST_DIR/update-ignore.err" "trying origin"
  assert_contains "$TEST_DIR/update-ignore.err" "starting current version"
  assert_not_contains "$TEST_DIR/update-ignore.err" "Killed"
  if kill -0 "$(cat "$TEST_DIR/probe.pid")" 2>/dev/null; then fail "the TERM-ignoring probe is still running"; fi

  for mode in fail empty; do
    if PATH="$bin_dir:$PATH" PEON_FETCH_TIMEOUT=invalid PROBE_MODE="$mode" PROBE_PID_FILE="$TEST_DIR/probe.pid" \
      TMPDIR="$TEST_DIR/update-tmp" bash -c 'SCRIPT_DIR=$1; source "$1/lib/config.sh"; offer_update stdio' _ "$ROOT" \
      >"$TEST_DIR/update-probe-failed.out" 2>"$TEST_DIR/update-probe-failed.err" </dev/null; then
      fail "an empty or failed public check offered an update"
    fi
    [ ! -s "$TEST_DIR/update-probe-failed.out" ] || fail "a failed probe added stdout"
    assert_contains "$TEST_DIR/update-probe-failed.err" "trying origin"
    assert_contains "$TEST_DIR/update-probe-failed.err" "starting current version"
  done
  set -- "$TEST_DIR/update-tmp"/peon-update.*
  [ ! -e "$1" ] || fail "the probe left its temporary file"

  PATH="$bin_dir:$PATH" GIT_TERMINAL_PROMPT=caller PROBE_PID_FILE="$TEST_DIR/probe.pid" \
    PROBE_ENV_LOG="$TEST_DIR/probe-env.log" PEON_UPDATE_PAUSE=0 \
    bash -c 'SCRIPT_DIR=$1; source "$1/lib/config.sh"; offer_update' _ "$ROOT" \
    >"$TEST_DIR/update-env.out" 2>"$TEST_DIR/update-env.err" <<<'y'
  [ "$(cat "$TEST_DIR/probe-env.log")" = $'rev-parse|caller\nsymbolic-ref|caller\nconfig|caller\nconfig|caller\nls-remote|0\nrev-parse|caller\nmerge-base|caller\ncat-file|caller\npull|0' ] ||
    fail "noninteractive Git settings were missing or reached another git command"

  PATH="$bin_dir:$PATH" GIT_TERMINAL_PROMPT=caller PROBE_MODE=fail PROBE_FALLBACK_MODE=success \
    PROBE_PID_FILE="$TEST_DIR/probe.pid" PROBE_PULL_SOURCE="$TEST_DIR/probe-pull-source" PEON_UPDATE_PAUSE=0 \
    bash -c 'SCRIPT_DIR=$1; source "$1/lib/config.sh"; offer_update stdio' _ "$ROOT" \
    >"$TEST_DIR/update-fallback.out" 2>"$TEST_DIR/update-fallback.err" <<<'y'
  [ "$(cat "$TEST_DIR/probe-pull-source")" = origin ] || fail "pull did not use the successful fallback"
  assert_contains "$TEST_DIR/update-fallback.err" "trying origin"
  assert_contains "$TEST_DIR/update-fallback.out" '{"update":1,"host":"'
  [ "$(wc -l <"$TEST_DIR/update-fallback.out" | tr -d ' ')" = 1 ] || fail "fallback added stdout to the stdio protocol"
  PATH="$bin_dir:$PATH" PROBE_MODE=empty PROBE_FALLBACK_MODE=success PROBE_PID_FILE="$TEST_DIR/probe.pid" \
    PEON_UPDATE_PAUSE=0 bash -c 'SCRIPT_DIR=$1; source "$1/lib/config.sh"; offer_update stdio' _ "$ROOT" \
    >"$TEST_DIR/update-empty-fallback.out" 2>"$TEST_DIR/update-empty-fallback.err" <<<'n' && fail "declined fallback reported a pull"
  assert_contains "$TEST_DIR/update-empty-fallback.err" "trying origin"
  assert_contains "$TEST_DIR/update-empty-fallback.out" '{"update":1,"host":"'
}

test_local_update_before_ssh() {
  command -v python3 >/dev/null || return 0
  local origin="$TEST_DIR/ssh-update-origin" source="$TEST_DIR/ssh-update-source" mine="$TEST_DIR/ssh-update-mine"
  local bin_dir="$TEST_DIR/ssh-update-bin" real_git
  real_git=$(command -v git)
  mkdir -p "$source/lib" "$source/web" "$bin_dir"
  cp "$ROOT/peon-code-web.sh" "$source/"
  cp "$ROOT/lib/config.sh" "$source/lib/"
  cp "$ROOT/lib/deps.sh" "$source/lib/"
  cp "$ROOT/web/server.py" "$ROOT/web/bridge.py" "$ROOT/web/launch.py" "$source/web/"
  git init -q -b main "$source"
  git -C "$source" add peon-code-web.sh lib/config.sh lib/deps.sh web/server.py web/bridge.py web/launch.py
  git -C "$source" -c user.name=t -c user.email=t@t commit -q -m one
  git clone -q --bare "$source" "$origin"
  git clone -q "$origin" "$mine"
  git -C "$source" -c user.name=t -c user.email=t@t commit -q --allow-empty -m two
  git -C "$source" push -q "$origin" main
  cat >"$bin_dir/git" <<'FAKE_GIT'
#!/usr/bin/env bash
[ "${3:-}" != ls-remote ] || printf 'probe\n' >>"$SSH_UPDATE_LOG"
exec "$REAL_GIT" "$@"
FAKE_GIT
  cat >"$bin_dir/ssh" <<'FAKE_SSH'
#!/usr/bin/env bash
grep -Fq 'update available upstream; pull now?' "$SSH_UPDATE_ERR" || exit 1
printf 'ssh\n' >>"$SSH_UPDATE_LOG"
printf '{"url":"http://127.0.0.1:9123/#%043d"}\n' 0
FAKE_SSH
  chmod +x "$bin_dir/git" "$bin_dir/ssh"
  # shellcheck disable=SC2094 # Fake SSH reads the update stderr after the launcher writes it.
  printf 'n\n' | PATH="$bin_dir:$PATH" REAL_GIT="$real_git" PEON_UPDATE_URL="$origin" \
    SSH_UPDATE_LOG="$TEST_DIR/ssh-update.log" SSH_UPDATE_ERR="$TEST_DIR/ssh-update.err" \
    "$mine/peon-code-web.sh" --ssh host --no-open --port 9123 \
    >"$TEST_DIR/ssh-update.out" 2>"$TEST_DIR/ssh-update.err"
  assert_contains "$TEST_DIR/ssh-update.err" 'update available upstream; pull now? [y/N]'
  assert_contains "$TEST_DIR/ssh-update.err" "not updated; later: git -C $mine pull"
  [ "$(cat "$TEST_DIR/ssh-update.log")" = $'probe\nssh' ] || fail "SSH started before the local check"
  assert_contains "$TEST_DIR/ssh-update.out" 'peon-code-web: http://127.0.0.1:9123/'
}

fake_bin=$(make_fake_commands)
# Root installer tests must leave this checkout's Git settings intact.
printf '#!/bin/sh\nexit 1\n' >"$fake_bin/git"
chmod +x "$fake_bin/git"
test_install_dependencies
test_install_guard
test_install_tmux_conf
test_install_git_hooks
test_update_offer
test_public_pull_keeps_fork_tracking
test_update_probe_timeout
test_local_update_before_ssh
echo "install: PASS"
