#!/usr/bin/env bash
set -euo pipefail
CASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/helpers.sh
. "$CASE_DIR/../helpers.sh"

# The launch line ends with the settings path as printf %q wrote it, so the
# pane's own shell quoting is what turns it back into a path.
settings_path() {
  local launch=$1 quoted=${1#*--settings }
  [ "$quoted" != "$launch" ] || fail "no --settings in the launch line: $launch"
  eval "printf '%s' $quoted"
}

# The deny families peon-code.sh declares, so the test checks the one list the
# deny file and the brief sentence are both built from.
load_git_deny() {
  local block
  block=$(sed -n '/^GIT_DENY=(/,/^)$/p' "$ROOT/peon-code.sh")
  # Bound what the eval runs: every line is the opener, the closer, or a row of
  # quoted git commands, so a reflowed array fails here instead of executing.
  if printf '%s\n' "$block" | grep -Eqv '^(GIT_DENY=\(|\)|( *"git [A-Za-z -]+")+)$'; then
    fail "GIT_DENY did not extract as a plain array literal"
  fi
  eval "$block"
  [ "${#GIT_DENY[@]}" -gt 0 ] || fail "no GIT_DENY list found in peon-code.sh"
}

# Only the main agent launches with full git: another claude pane adds a
# --settings deny file, a claude pane that passes its own --settings keeps it,
# and every pane but main gets the hard git prohibition line in its brief.
test_git_deny_settings() {
  local fake_bin=$1 log="$TEST_DIR/tmux-deny.log" home_dir="$TEST_DIR/home-deny"
  local work_dir="$TEST_DIR/deny-work" boss_launch helper_launch own_launch
  local eq_launch yolo_launch
  local settings rule boss_brief helper_brief impl_brief
  mkdir -p "$home_dir" "$work_dir"
  printf '*boss claude -\nhelper claude -\nown claude --settings /user/own.json -\neq claude --settings=/user/eq.json -\nyolo claude --dangerously-skip-permissions -\nimpl codex -\n' \
    >"$work_dir/peon-code.conf"

  (
    cd "$work_dir"
    PATH="$fake_bin:$PATH" HOME="$home_dir" TMPDIR="$TEST_DIR" \
      FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=launch FAKE_TMUX_PANES=6 \
      "$ROOT/peon-code.sh" -c "$work_dir/peon-code.conf" deny-test
  ) >"$TEST_DIR/deny.out" 2>"$TEST_DIR/deny.err" || true

  boss_launch=$(grep -F 'buffer-content:claude' "$log" | sed -n '1p')
  helper_launch=$(grep -F 'buffer-content:claude' "$log" | sed -n '2p')
  own_launch=$(grep -F 'buffer-content:claude' "$log" | sed -n '3p')
  eq_launch=$(grep -F 'buffer-content:claude' "$log" | sed -n '4p')
  yolo_launch=$(grep -F 'buffer-content:claude' "$log" | sed -n '5p')
  [ -n "$yolo_launch" ] || fail "the deny test did not record all five claude launches"
  case $boss_launch in
    *--settings*) fail "the main agent was launched with --settings" ;;
  esac
  case $helper_launch in
    *--settings*) ;;
    *) fail "a non-main claude agent was launched without --settings" ;;
  esac
  assert_not_contains "$log" "buffer-content:codex --settings"

  settings=$(settings_path "$helper_launch")
  [ -f "$settings" ] || fail "the deny settings file was not written: $settings"
  # A pane passing its own --settings keeps it: claude reads one such flag.
  [ "$own_launch" = "buffer-content:claude --settings /user/own.json" ] ||
    fail "a claude pane with its own --settings was launched with: $own_launch"
  [ "$eq_launch" = "buffer-content:claude --settings=/user/eq.json" ] ||
    fail "a claude pane with its own --settings= was launched with: $eq_launch"
  # A pane that skips permission checks still gets the file, which does nothing.
  case $yolo_launch in
    *--settings*) ;;
    *) fail "a non-main claude agent was launched without --settings" ;;
  esac
  # Both silent opt-outs are named on stderr so the operator sees them.
  assert_contains "$TEST_DIR/deny.err" \
    "peon-code: own passes its own --settings, so it gets no git deny file"
  assert_contains "$TEST_DIR/deny.err" \
    "peon-code: eq passes its own --settings, so it gets no git deny file"
  assert_contains "$TEST_DIR/deny.err" \
    "peon-code: yolo passes --dangerously-skip-permissions, so the git deny file has no effect"
  assert_not_contains "$TEST_DIR/deny.err" "peon-code: helper passes"

  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json, sys; json.load(open(sys.argv[1]))' "$settings" ||
      fail "the deny settings file is not valid JSON"
  fi
  assert_contains "$settings" '"deny"'
  # Pinned by name, since the loop below reads the same array it checks.
  assert_contains "$settings" '"Bash(git commit)"'
  assert_contains "$settings" '"Bash(git rm)"'
  load_git_deny
  for rule in "${GIT_DENY[@]}"; do
    assert_contains "$settings" "\"Bash($rule)\""
    assert_contains "$settings" "\"Bash($rule:*)\""
  done

  # Brief files, in pane order, from the @peon_brief options the launch set.
  boss_brief=$(grep -F '@peon_brief' "$log" | sed -n '1p')
  boss_brief=${boss_brief##* }
  helper_brief=$(grep -F '@peon_brief' "$log" | sed -n '2p')
  helper_brief=${helper_brief##* }
  impl_brief=$(grep -F '@peon_brief' "$log" | sed -n '6p')
  impl_brief=${impl_brief##* }
  [ -f "$impl_brief" ] || fail "the deny test did not record all six brief files"
  # Commits belong to the main pane, whichever pane is reading the brief.
  for rule in "$boss_brief" "$helper_brief" "$impl_brief"; do
    assert_contains "$rule" "Commits happen only when the user asks for one, and only in the boss pane"
    assert_contains "$rule" "any other agent asked to commit messages that pane instead of committing"
  done
  assert_not_contains "$boss_brief" "Hard prohibition for this pane"
  assert_contains "$helper_brief" "Hard prohibition for this pane"
  assert_contains "$impl_brief" "Hard prohibition for this pane"
  # The prohibition sentence names every family in the deny list.
  for rule in "${GIT_DENY[@]}"; do
    assert_contains "$helper_brief" "${rule#git }"
  done
}

# With no * in the config, main is the first manager-role agent: that pane
# keeps full git even though it is not pane 0.
test_git_deny_unstarred_main() {
  local fake_bin=$1 log="$TEST_DIR/tmux-unstarred.log"
  local home_dir="$TEST_DIR/home-unstarred" work_dir="$TEST_DIR/unstarred-work"
  local boss_launch helper_launch front_brief boss_brief
  mkdir -p "$home_dir" "$work_dir"
  printf 'front codex -\nboss claude manager\nhelper claude -\n' >"$work_dir/peon-code.conf"

  (
    cd "$work_dir"
    PATH="$fake_bin:$PATH" HOME="$home_dir" TMPDIR="$TEST_DIR" \
      FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=launch FAKE_TMUX_PANES=3 \
      "$ROOT/peon-code.sh" -c "$work_dir/peon-code.conf" unstarred-test
  ) >"$TEST_DIR/unstarred.out" 2>"$TEST_DIR/unstarred.err" || true

  boss_launch=$(grep -F 'buffer-content:claude' "$log" | sed -n '1p')
  helper_launch=$(grep -F 'buffer-content:claude' "$log" | sed -n '2p')
  [ -n "$helper_launch" ] || fail "the unstarred test did not record both claude launches"
  case $boss_launch in
    *--settings*) fail "the fallback main agent was launched with --settings" ;;
  esac
  case $helper_launch in
    *--settings*) ;;
    *) fail "a non-main claude agent was launched without --settings" ;;
  esac

  front_brief=$(grep -F '@peon_brief' "$log" | sed -n '1p')
  front_brief=${front_brief##* }
  boss_brief=$(grep -F '@peon_brief' "$log" | sed -n '2p')
  boss_brief=${boss_brief##* }
  [ -f "$boss_brief" ] || fail "the unstarred test did not record the main pane's brief"
  # The manager role carries the git text, and the shared rule names its pane.
  assert_contains "$boss_brief" "Git actions the user asks for, a commit above all, you run yourself in your own pane"
  assert_contains "$boss_brief" "only in the boss pane"
  assert_not_contains "$boss_brief" "Hard prohibition for this pane"
  assert_contains "$front_brief" "Hard prohibition for this pane"
}

fake_bin=$(make_fake_commands)
test_git_deny_settings "$fake_bin"
test_git_deny_unstarred_main "$fake_bin"
echo "git_deny: PASS"
