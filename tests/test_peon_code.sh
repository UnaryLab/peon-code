#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/peon-code-test.XXXXXX")

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local file=$1 text=$2
  grep -Fq -- "$text" "$file" || fail "$file does not contain: $text"
}

assert_not_contains() {
  local file=$1 text=$2
  if grep -Fq -- "$text" "$file"; then
    fail "$file contains: $text"
  fi
}

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
  (
    cd "$TEST_DIR"
    HOME="$home_dir" "$bin_dir/peon-code" -h
  ) >"$TEST_DIR/installed-help.out"
  assert_contains "$TEST_DIR/installed-help.out" "peon-code.sh [-c file]"
}

make_fake_commands() {
  local bin_dir="$TEST_DIR/fake-bin"
  mkdir -p "$bin_dir"
  cat >"$bin_dir/tmux" <<'FAKE_TMUX'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"$FAKE_TMUX_LOG"
case ${1:-} in
  set|set-option)
    case " $* " in
      *" -t ="*) exit 2 ;;
    esac
    ;;
  split-window|select-layout|list-panes)
    case " $* " in
      *" -t ="*":agents "*) exit 2 ;;
    esac
    ;;
esac
case ${1:-} in
  has-session)
    [ "${FAKE_TMUX_MODE:-}" != launch ]
    ;;
  show-options)
    case " $* " in
      *" -t ="*) exit 2 ;;
      *" @peon_brief "*) printf '%s\n' "${FAKE_TMUX_BRIEF:-}"; exit 0 ;;
    esac
    [ "${FAKE_TMUX_MODE:-}" = owned ] && printf '1\n'
    exit 0
    ;;
  list-panes)
    case "$*" in
      *'#{pane_id} #{pane_current_command} #{@peon_name}'*)
        printf '%%1 codex impl\n'
        ;;
      *'#{pane_id}'*)
        for ((p = 1; p <= ${FAKE_TMUX_PANES:-1}; p++)); do
          printf '%%%d\n' "$p"
        done
        ;;
      *'#{@peon_name}'*)
        [ "${FAKE_TMUX_MODE:-}" = legacy ] && printf 'impl\n'
        ;;
    esac
    ;;
  display)
    case "$*" in
      *cursor_y*) printf '1\n' ;;
      *pane_in_mode*) printf '%s\n' "${FAKE_IN_MODE:-0}" ;;
      *) printf '%s\n' "${FAKE_TMUX_CMD:-zsh}" ;;
    esac
    ;;
  capture-pane)
    cap=${FAKE_TMUX_CAPTURE:-}
    # What the pane shows once a paste has reached it, when the test sets one.
    grep -Fq paste-buffer "$FAKE_TMUX_LOG" && cap=${FAKE_TMUX_CAPTURE_AFTER:-$cap}
    printf '%s\n' "$cap"
    ;;
  load-buffer)
    content=$(cat)
    printf 'buffer-content:%s\n' "$content" >>"$FAKE_TMUX_LOG"
    exit "${FAKE_LOAD_BUFFER_EXIT:-0}"
    ;;
esac
FAKE_TMUX
  cat >"$bin_dir/sleep" <<'FAKE_SLEEP'
#!/usr/bin/env bash
exit 0
FAKE_SLEEP
  chmod +x "$bin_dir/tmux" "$bin_dir/sleep"
  printf '%s\n' "$bin_dir"
}

test_session_ownership() {
  local fake_bin=$1 log="$TEST_DIR/tmux-ownership.log" home_dir="$TEST_DIR/home-tmux"
  mkdir -p "$home_dir"

  if PATH="$fake_bin:$PATH" HOME="$home_dir" FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=foreign \
    "$ROOT/peon-code.sh" dismiss foreign >"$TEST_DIR/foreign.out" 2>"$TEST_DIR/foreign.err"; then
    fail "dismiss accepted a foreign session"
  fi
  assert_contains "$TEST_DIR/foreign.err" "session foreign was not created by peon-code"
  if grep -Fq "kill-session" "$log"; then
    fail "dismiss killed a foreign session"
  fi

  : >"$log"
  PATH="$fake_bin:$PATH" HOME="$home_dir" FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=owned \
    "$ROOT/peon-code.sh" dismiss owned >"$TEST_DIR/owned.out"
  assert_contains "$log" "kill-session -t =owned"

  : >"$log"
  if PATH="$fake_bin:$PATH" HOME="$home_dir" FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=legacy \
    "$ROOT/peon-code.sh" dismiss legacy >"$TEST_DIR/legacy.out" 2>"$TEST_DIR/legacy.err"; then
    fail "dismiss accepted an unmarked legacy session"
  fi
  assert_contains "$TEST_DIR/legacy.err" "session legacy was not created by peon-code"
  if grep -Fq "kill-session" "$log"; then
    fail "dismiss killed an unmarked legacy session"
  fi
}

test_unique_buffers_and_launch_failure() {
  local fake_bin=$1 log="$TEST_DIR/tmux-buffer.log" home_dir="$TEST_DIR/home-buffer"
  mkdir -p "$home_dir" "$TEST_DIR/work"

  # The pane here never shows the paste, so the run ends nonzero; what this
  # case checks is the buffer name.
  PATH="$fake_bin:$PATH" HOME="$home_dir" FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=owned \
    "$ROOT/peon-code.sh" msg all hello owned >"$TEST_DIR/msg.out" 2>"$TEST_DIR/msg.err" || true
  grep -Eq 'load-buffer -b peon-code-[0-9]+-1 -' "$log" ||
    fail "msg did not use a unique tmux buffer"

  : >"$log"
  (
    cd "$TEST_DIR/work"
    PATH="$fake_bin:$PATH" HOME="$home_dir" TMPDIR="$TEST_DIR" \
      FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=launch \
      "$ROOT/peon-code.sh" launch ./missing-agent
  ) >"$TEST_DIR/launch.out" 2>"$TEST_DIR/launch.err" &&
    fail "a launch with a dead agent succeeded"
  assert_contains "$TEST_DIR/launch.err" "agents failed to start; killed session launch: ./missing-agent"
  assert_contains "$log" "set-option -t launch @peon_code 1"
  assert_contains "$log" "list-panes -t launch:agents"
  assert_contains "$log" "kill-session -t =launch"
  assert_not_contains "$log" "set-option -t =launch"
  assert_not_contains "$TEST_DIR/launch.out" "session launch is ready"
  grep -Eq 'buffer-content:\./missing-agent .*/0\.md' "$log" ||
    fail "a numeric brief filename was not used"
  grep -Eq 'load-buffer -b peon-code-[0-9]+-1 -' "$log" ||
    fail "agent launch did not use a unique tmux buffer"
  if grep -Fq "/./missing-agent.md" "$TEST_DIR/launch.err"; then
    fail "a slash-containing command was used as a brief filename"
  fi
}

# A launch into panes whose shell prompt draws the same marker a CLI does:
# the command line is submitted anyway, since the shell prompt is not a box
# peon-code can check, and a brief the box never shows leaves the run going.
test_launch_with_prompt_box() {
  local fake_bin=$1 log="$TEST_DIR/tmux-prompt-box.log" home_dir="$TEST_DIR/home-prompt-box"
  local work_dir="$TEST_DIR/prompt-box-work"
  # A shell prompt ending in the marker, with a clock on the right, so the box
  # reads back non-empty and never matches what was pasted.
  local prompt_box='work on main
❯ [12:34:56]'
  mkdir -p "$home_dir" "$work_dir"
  printf 'boss claude -\n' >"$work_dir/peon-code.conf"

  : >"$log"
  (
    cd "$work_dir"
    PATH="$fake_bin:$PATH" HOME="$home_dir" TMPDIR="$TEST_DIR" \
      FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=launch FAKE_TMUX_CMD=node \
      FAKE_TMUX_CAPTURE="$prompt_box" \
      "$ROOT/peon-code.sh" prompt-box
  ) >"$TEST_DIR/prompt-box.out" 2>"$TEST_DIR/prompt-box.err" </dev/null ||
    fail "launch gave up on a pane whose shell prompt draws a box"
  assert_contains "$TEST_DIR/prompt-box.out" "session prompt-box is ready"
  assert_contains "$log" "buffer-content:claude"
  assert_contains "$TEST_DIR/prompt-box.err" \
    "no Enter sent to boss %1: the brief is in its box for you to submit"
  # One Enter: the command line got it, the brief did not.
  [ "$(grep -c -Fx -- 'send-keys -t %1 Enter' "$log")" = 1 ] ||
    fail "launch pressed the wrong number of Enters into a pane with a prompt box"
}

test_config_loading() {
  local fake_bin=$1 log="$TEST_DIR/tmux-config.log" home_dir="$TEST_DIR/home-config"
  local config_dir="$TEST_DIR/config" work_dir="$TEST_DIR/config-work" line brief_file
  mkdir -p "$home_dir" "$config_dir" "$work_dir"
  printf 'Keep changes focused.\n' >"$config_dir/custom.md"
  printf 'boss ./missing-agent ./custom.md\n' >"$config_dir/team.conf"

  (
    cd "$work_dir"
    PATH="$fake_bin:$PATH" HOME="$home_dir" TMPDIR="$TEST_DIR" \
      FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=launch \
      "$ROOT/peon-code.sh" -c "$config_dir/team.conf" config-test
  ) >"$TEST_DIR/config.out" 2>"$TEST_DIR/config.err" &&
    fail "a config launch with a dead agent succeeded"
  assert_contains "$TEST_DIR/config.err" "agents failed to start; killed session config-test: boss"
  assert_contains "$log" "kill-session -t =config-test"
  line=$(grep -F "buffer-content:" "$log" | tail -1)
  brief_file=${line#*"\$(cat "}
  brief_file=${brief_file%%')"'*}
  [ -n "$brief_file" ] || fail "the config launch did not record a brief file"
  assert_contains "$brief_file" "Keep changes focused."
  # The message prefix names the sender's CLI, its agent name, and its pane.
  assert_contains "$brief_file" "Start every message you send with [from ./missing-agent boss %"
  # Agents send through the subcommand, which checks and pastes in one run,
  # instead of the raw send-keys recipe that left a gap between the two.
  assert_contains "$brief_file" "$ROOT/peon-code.sh send <other-pane-id> - <<'PEON'"
  assert_contains "$brief_file" "3. Held sends: send makes the box check and the paste back to back"
  # A message never substitutes for closing the board row.
  assert_contains "$brief_file" "7. Task completion: set your board row to done before you send the completion message."
  assert_not_contains "$brief_file" "tmux send-keys -t <other-pane-id> -l"
  # The message goes in on stdin, so nothing asks agents to mind their quoting.
  assert_not_contains "$brief_file" "Avoid single quotes"
}

# Rule 7 differs by pane: the main pane's brief carries the manager
# verification sentence too, every other pane gets the worker sentence alone.
test_brief_rule7_variants() {
  local fake_bin=$1 log="$TEST_DIR/tmux-rule7.log" home_dir="$TEST_DIR/home-rule7"
  local work_dir="$TEST_DIR/rule7-work" line boss_brief helper_brief
  local worker_rule="7. Task completion: set your board row to done before you send the completion message. A task is not done until its row says done; a message never substitutes for the row edit."
  local manager_rule="On receiving a completion message, verify the sender's board row is done and set it to done yourself if it is not, before acknowledging the work or dispatching new work."
  local delete_rule="Once the work is verified, delete the row from the board, but only after the reviewer records a verdict on it if the team has one; the board lists only open work."
  mkdir -p "$home_dir" "$work_dir"
  printf '*boss ./missing-agent -\nhelper ./missing-agent -\n' >"$work_dir/peon-code.conf"

  (
    cd "$work_dir"
    PATH="$fake_bin:$PATH" HOME="$home_dir" TMPDIR="$TEST_DIR" \
      FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=launch FAKE_TMUX_PANES=2 \
      "$ROOT/peon-code.sh" -c "$work_dir/peon-code.conf" rule7-test
  ) >"$TEST_DIR/rule7.out" 2>"$TEST_DIR/rule7.err" || true

  line=$(grep -F "buffer-content:" "$log" | sed -n '1p')
  boss_brief=${line#*"\$(cat "}
  boss_brief=${boss_brief%%')"'*}
  line=$(grep -F "buffer-content:" "$log" | sed -n '2p')
  helper_brief=${line#*"\$(cat "}
  helper_brief=${helper_brief%%')"'*}
  [ -n "$boss_brief" ] || fail "rule7 test did not record the main pane's brief file"
  [ -n "$helper_brief" ] || fail "rule7 test did not record the other pane's brief file"

  assert_contains "$boss_brief" "$worker_rule $manager_rule $delete_rule"
  assert_contains "$helper_brief" "$worker_rule"
  assert_not_contains "$helper_brief" "$manager_rule"
  assert_not_contains "$helper_brief" "$delete_rule"
}

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

# A tmux stand-in for send: the pane keeps its before-the-paste look until a
# paste is logged, then keeps it for FAKE_SETTLE more box reads before showing
# the box the message landed in. A box read is one cursor lookup followed by
# one capture, so the capture count is the number of polls send made.
SEND_LOG="$TEST_DIR/tmux-send.log"
make_send_bin() {
  local fake_bin=$1 bin_dir="$TEST_DIR/send-bin"
  mkdir -p "$bin_dir"
  cp "$fake_bin/sleep" "$bin_dir/sleep"
  cat >"$bin_dir/tmux" <<'FAKE_TMUX'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_TMUX_LOG"
pane=%1
case "$*" in *%2*) pane=%2 ;; esac
state=before
grep -Fq paste-buffer "$FAKE_TMUX_LOG" && state=after
reads=0
[ -f "$FAKE_TMUX_LOG.reads" ] && reads=$(cat "$FAKE_TMUX_LOG.reads")
box=$FAKE_BOX
cursor=$FAKE_CURSOR
in_mode=${FAKE_IN_MODE:-0}
if [ "$state" = after ]; then
  in_mode=${FAKE_IN_MODE_AFTER:-0}
  if [ "$reads" -ge "${FAKE_SETTLE:-0}" ]; then
    box=$FAKE_BOX_AFTER
    cursor=$FAKE_CURSOR_AFTER
  fi
fi
case ${1:-} in
  display)
    case "$*" in
      *pane_current_command*) printf '%s\n' "${FAKE_CMD:-node}" ;;
      *pane_in_mode*) printf '%s\n' "$in_mode" ;;
      *cursor_x*) printf '%s\n' "$cursor" ;;
      *cursor_y*) printf '%s\n' "${cursor##* }" ;;
    esac
    ;;
  capture-pane)
    printf '%s\n' "$box"
    [ "$state" = after ] && printf '%s' "$((reads + 1))" >"$FAKE_TMUX_LOG.reads"
    ;;
  show-options) printf '%s\n' "${FAKE_PEON_NAME-impl}" ;;
  load-buffer) printf 'buffer-content:%s\n' "$(cat)" >>"$FAKE_TMUX_LOG" ;;
  paste-buffer)
    # A pane named in FAKE_PASTE_FAIL refuses the paste.
    [ "$pane" = "${FAKE_PASTE_FAIL:-}" ] && exit 1
    ;;
esac
exit 0
FAKE_TMUX
  chmod +x "$bin_dir/tmux"
  printf '%s\n' "$bin_dir"
}

reset_send_log() {
  : >"$SEND_LOG"
  rm -f "$SEND_LOG.reads"
}

# How many times send read the target's box.
send_captures() {
  grep -c '^capture-pane' "$SEND_LOG" || true
}

# One refused send. Arguments after the wanted message are the FAKE_ settings
# that put the pane in the state under test.
assert_send_refused() {
  local what=$1 want=$2 out="$TEST_DIR/send-refuse.out" err="$TEST_DIR/send-refuse.err"
  shift 2
  reset_send_log
  if PATH="$SEND_BIN:$PATH" FAKE_TMUX_LOG="$SEND_LOG" \
    env "$@" "$ROOT/peon-code.sh" send %2 'hello world' >"$out" 2>"$err"; then
    fail "send pasted into $what"
  fi
  assert_contains "$err" "$want"
  assert_not_contains "$SEND_LOG" "paste-buffer"
  assert_not_contains "$SEND_LOG" "send-keys"
}

# Every state that must stop a send before anything is pasted.
test_send_refuses() {
  local empty_box busy_box menu_box codex_menu_box bare_box
  empty_box='output line
❯
────'
  busy_box='output line
❯ busy text
────'
  # A menu draws the marker on its selected row with the cursor right after
  # it, so the box measures empty and only the menu itself gives it away.
  menu_box='Do you trust this folder?
❯ 1. Yes, I trust this folder
  2. No, exit'
  codex_menu_box='Do you trust the contents of this directory?
› 1. Yes, continue
  2. No, quit'
  bare_box='some other CLI
> ready
────'

  assert_send_refused "a box that already had typed text" "target box busy after 10 tries, giving up" \
    FAKE_BOX="$busy_box" FAKE_CURSOR='11 1'
  # A box that stays busy is read once per try, so ten reads show send
  # retried to its cap before giving up.
  [ "$(send_captures)" = 10 ] || fail "send made $(send_captures) box reads, expected 10"
  # The user typed, then moved the cursor back to the start of the line: the
  # text sits after the cursor, and the box is busy all the same.
  assert_send_refused "a box holding text the cursor had moved back over" "target box busy after 10 tries, giving up" \
    FAKE_BOX="$busy_box" FAKE_CURSOR='2 1'
  # In copy mode a paste lands but Enter goes to the copy-mode key table.
  assert_send_refused "a pane in copy mode" "is in copy mode after 10 tries, giving up" \
    FAKE_BOX="$empty_box" FAKE_CURSOR='2 1' FAKE_IN_MODE=1
  assert_send_refused "a pane sitting on a menu" "is on a dialog or a menu after 10 tries, giving up" \
    FAKE_BOX="$menu_box" FAKE_CURSOR='1 1'
  assert_send_refused "a codex pane sitting on a menu" "is on a dialog or a menu after 10 tries, giving up" \
    FAKE_BOX="$codex_menu_box" FAKE_CURSOR='1 1'
  # No marker means no box peon-code can measure, which no waiting fixes, so
  # send dies on the first read and says to send it by hand.
  assert_send_refused "a pane drawing no prompt marker" "draws no prompt marker peon-code knows" \
    FAKE_BOX="$bare_box" FAKE_CURSOR='7 1'
  [ "$(send_captures)" = 1 ] || fail "send made $(send_captures) box reads, expected 1"
  assert_send_refused "a pane back at a shell" "back at a shell" \
    FAKE_BOX="$empty_box" FAKE_CURSOR='2 1' FAKE_CMD=zsh
  # Without the launch-time pane option, send would reach any pane on the
  # tmux server, agent pane or not.
  assert_send_refused "a pane peon-code did not launch" "is not a peon-code agent pane" \
    FAKE_BOX="$empty_box" FAKE_CURSOR='2 1' FAKE_PEON_NAME=
}

# What send does once it has pasted: it polls the box and presses Enter only
# for a box holding exactly the message.
test_send_delivers() {
  local empty_box sent_box extra_box payload keys
  empty_box='output line
❯
────'
  sent_box='output line
❯ hello world
────'
  extra_box='output line
❯ hello worldXY
────'

  # The box holds the pasted message only from the fourth poll on, so a send
  # that stopped polling early would never see it.
  reset_send_log
  PATH="$SEND_BIN:$PATH" FAKE_TMUX_LOG="$SEND_LOG" FAKE_SETTLE=3 \
    FAKE_BOX="$empty_box" FAKE_CURSOR='2 1' \
    FAKE_BOX_AFTER="$sent_box" FAKE_CURSOR_AFTER='13 1' \
    "$ROOT/peon-code.sh" send %2 'hello world' >"$TEST_DIR/send-ok.out"
  assert_contains "$TEST_DIR/send-ok.out" "sent to %2"
  assert_contains "$SEND_LOG" "buffer-content:hello world"
  grep -Eq 'paste-buffer -b peon-code-[0-9]+-2 -dpt %2' "$SEND_LOG" ||
    fail "send did not paste through a unique tmux buffer"
  assert_contains "$SEND_LOG" "send-keys -t %2 Enter"
  [ "$(send_captures)" = 5 ] || fail "send made $(send_captures) box reads, expected 5"

  # A box holding more than the message never matches, so send polls to its
  # cap, leaves the box alone, and says so.
  reset_send_log
  if PATH="$SEND_BIN:$PATH" FAKE_TMUX_LOG="$SEND_LOG" \
    FAKE_BOX="$empty_box" FAKE_CURSOR='2 1' \
    FAKE_BOX_AFTER="$extra_box" FAKE_CURSOR_AFTER='15 1' \
    "$ROOT/peon-code.sh" send %2 'hello world' >"$TEST_DIR/send-extra.out" 2>"$TEST_DIR/send-extra.err"; then
    fail "send submitted a box holding more than the message"
  fi
  assert_contains "$TEST_DIR/send-extra.err" "no Enter sent"
  assert_contains "$SEND_LOG" "paste-buffer"
  assert_not_contains "$SEND_LOG" "send-keys"
  [ "$(send_captures)" = 11 ] || fail "send made $(send_captures) box reads, expected 11"

  # A paste tmux refused leaves the pane untouched, so the run says nothing
  # was sent instead of stopping without a word.
  reset_send_log
  if PATH="$SEND_BIN:$PATH" FAKE_TMUX_LOG="$SEND_LOG" FAKE_PASTE_FAIL=%2 \
    FAKE_BOX="$empty_box" FAKE_CURSOR='2 1' \
    "$ROOT/peon-code.sh" send %2 'hello world' \
    >"$TEST_DIR/send-refused.out" 2>"$TEST_DIR/send-refused.err"; then
    fail "send reported success after tmux refused the paste"
  fi
  assert_contains "$TEST_DIR/send-refused.err" "no message sent: tmux refused the paste"
  assert_not_contains "$SEND_LOG" "send-keys"

  # A CLI that collapses a multi-line paste into a placeholder row still gets
  # the Enter: the box was empty before the paste, so one placeholder is the
  # message. One form per supported CLI.
  local placeholder
  for placeholder in '[Pasted text #2 +15 lines]' '[Pasted Content 1234 chars]' '[Paste #2 - 15 lines]'; do
    reset_send_log
    PATH="$SEND_BIN:$PATH" FAKE_TMUX_LOG="$SEND_LOG" \
      FAKE_BOX="$empty_box" FAKE_CURSOR='2 1' \
      FAKE_BOX_AFTER="output line
❯ $placeholder
────" FAKE_CURSOR_AFTER='28 1' \
      "$ROOT/peon-code.sh" send %2 - >"$TEST_DIR/send-collapsed.out" <<'PEON'
line one
line two
PEON
    assert_contains "$TEST_DIR/send-collapsed.out" "sent to %2"
    assert_contains "$SEND_LOG" "send-keys -t %2 Enter"
  done

  # codex draws › as its prompt marker; its box reads and delivers all the
  # same, whether the paste shows literally or as its collapsed placeholder.
  reset_send_log
  PATH="$SEND_BIN:$PATH" FAKE_TMUX_LOG="$SEND_LOG" \
    FAKE_BOX='output line
›
────' FAKE_CURSOR='2 1' \
    FAKE_BOX_AFTER='output line
› hello world
────' FAKE_CURSOR_AFTER='13 1' \
    "$ROOT/peon-code.sh" send %2 'hello world' >"$TEST_DIR/send-codex.out"
  assert_contains "$TEST_DIR/send-codex.out" "sent to %2"
  assert_contains "$SEND_LOG" "send-keys -t %2 Enter"

  # A placeholder with trailing typed text is not the message alone.
  reset_send_log
  if PATH="$SEND_BIN:$PATH" FAKE_TMUX_LOG="$SEND_LOG" \
    FAKE_BOX="$empty_box" FAKE_CURSOR='2 1' \
    FAKE_BOX_AFTER='output line
❯ [Pasted text #2 +15 lines] and more
────' FAKE_CURSOR_AFTER='37 1' \
    "$ROOT/peon-code.sh" send %2 'hello world' >/dev/null 2>"$TEST_DIR/send-collapsed-extra.err"; then
    fail "send submitted a placeholder box holding extra text"
  fi
  assert_contains "$TEST_DIR/send-collapsed-extra.err" "no Enter sent"
  assert_not_contains "$SEND_LOG" "send-keys"

  # A pane that enters copy mode after the paste keeps the message: Enter
  # would go to the copy-mode key table instead of the agent.
  reset_send_log
  if PATH="$SEND_BIN:$PATH" FAKE_TMUX_LOG="$SEND_LOG" FAKE_IN_MODE_AFTER=1 \
    FAKE_BOX="$empty_box" FAKE_CURSOR='2 1' \
    FAKE_BOX_AFTER="$sent_box" FAKE_CURSOR_AFTER='13 1' \
    "$ROOT/peon-code.sh" send %2 'hello world' >"$TEST_DIR/send-mode.out" 2>"$TEST_DIR/send-mode.err"; then
    fail "send pressed Enter on a pane in copy mode"
  fi
  assert_contains "$TEST_DIR/send-mode.err" "went into copy mode"
  assert_contains "$SEND_LOG" "paste-buffer"
  assert_not_contains "$SEND_LOG" "send-keys"

  # A bracketed-paste terminator in the message would end the paste early and
  # hand the rest to the receiving agent as keystrokes; it never gets pasted.
  reset_send_log
  payload=$(printf 'hello \033[201~\rrm -rf /tmp/peon-x')
  PATH="$SEND_BIN:$PATH" FAKE_TMUX_LOG="$SEND_LOG" \
    FAKE_BOX="$empty_box" FAKE_CURSOR='2 1' \
    FAKE_BOX_AFTER='output line
❯ hello [201~rm -rf /tmp/peon-x
────' FAKE_CURSOR_AFTER='31 1' \
    "$ROOT/peon-code.sh" send %2 "$payload" >"$TEST_DIR/send-esc.out"
  assert_contains "$TEST_DIR/send-esc.out" "sent to %2"
  assert_contains "$SEND_LOG" "buffer-content:hello [201~rm -rf /tmp/peon-x"
  if grep -Fq "$(printf '\033')" "$SEND_LOG"; then
    fail "send pasted an escape character into the pane"
  fi
  keys=$(grep -c '^send-keys' "$SEND_LOG" || true)
  [ "$keys" = 1 ] || fail "send made $keys send-keys calls, expected only the Enter"

  # A message of - comes in on stdin, so quoting it is the shell's problem,
  # not the sending agent's.
  reset_send_log
  PATH="$SEND_BIN:$PATH" FAKE_TMUX_LOG="$SEND_LOG" \
    FAKE_BOX="$empty_box" FAKE_CURSOR='2 1' \
    FAKE_BOX_AFTER="output line
❯ it is the user's box
────" FAKE_CURSOR_AFTER='21 1' \
    "$ROOT/peon-code.sh" send %2 - >"$TEST_DIR/send-stdin.out" <<'PEON'
it is the user's box
PEON
  assert_contains "$TEST_DIR/send-stdin.out" "sent to %2"
  assert_contains "$SEND_LOG" "buffer-content:it is the user's box"
  assert_contains "$SEND_LOG" "send-keys -t %2 Enter"
}

# Every agent must reopen its own thread: same-CLI panes share a directory,
# so a per-agent marker is what keeps them off each other's conversation.
test_resume_picks_each_agent_thread() {
  local fake_bin=$1 log="$TEST_DIR/tmux-resume.log" home_dir="$TEST_DIR/home-resume"
  local work_dir="$TEST_DIR/resume-work" claude_dir codex_dir slug launch
  local copilot_dir gemini_dir qwen_dir hash
  mkdir -p "$home_dir" "$work_dir"
  work_dir=$(cd "$work_dir" && pwd)  # the launcher sees the normalized path
  slug=${work_dir//[^A-Za-z0-9]/-}
  claude_dir="$home_dir/.claude/projects/$slug"
  codex_dir="$home_dir/.codex/sessions/2026/07/26"
  copilot_dir="$home_dir/.copilot/session-state/44444444-4444-4444-4444-444444444444"
  hash=$(printf '%s' "$work_dir" | shasum -a 256 2>/dev/null) ||
    hash=$(printf '%s' "$work_dir" | sha256sum)
  gemini_dir="$home_dir/.gemini/tmp/${hash%% *}/chats"
  qwen_dir="$home_dir/.qwen/projects/$slug/chats"
  mkdir -p "$claude_dir" "$codex_dir" "$copilot_dir" "$gemini_dir" "$qwen_dir"
  printf 'agent boss of peon-code session resume-test, in pane\n' \
    >"$claude_dir/11111111-1111-1111-1111-111111111111.jsonl"
  printf 'agent second of peon-code session resume-test, in pane\n' \
    >"$claude_dir/22222222-2222-2222-2222-222222222222.jsonl"
  printf '{"cwd":"%s"}\nagent impl of peon-code session resume-test, in pane\n' "$work_dir" \
    >"$codex_dir/rollout-2026-07-26T00-00-00-33333333-3333-3333-3333-333333333333.jsonl"
  printf '{"type":"session.start","data":{"context":{"cwd":"%s"}}}\nagent cop of peon-code session resume-test, in pane\n' "$work_dir" \
    >"$copilot_dir/events.jsonl"
  # One line holding a nested sessionId after the real one: the top-level id must win.
  printf '{"sessionId":"55555555-5555-5555-5555-555555555555","messages":[{"text":"agent gem of peon-code session resume-test, in pane"}],"extra":{"sessionId":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}}\n' \
    >"$gemini_dir/session-20260726-000000-55555555.jsonl"
  printf 'agent qw of peon-code session resume-test, in pane\n' \
    >"$qwen_dir/66666666-6666-6666-6666-666666666666.jsonl"
  # A qwen id can be a saved-chat tag shorter than a uuid.
  printf 'agent qw2 of peon-code session resume-test, in pane\n' \
    >"$qwen_dir/mytag.jsonl"
  sleep 1  # the decoy transcripts sort newer than the real ones
  printf 'agent boss of peon-code session resume-test2, in pane\n' \
    >"$claude_dir/99999999-9999-9999-9999-999999999999.jsonl"
  # Same marker, other directory: the copilot store is shared across directories.
  mkdir -p "$home_dir/.copilot/session-state/88888888-8888-8888-8888-888888888888"
  printf '{"type":"session.start","data":{"context":{"cwd":"%s"}}}\nagent cop of peon-code session resume-test, in pane\n' "$work_dir/elsewhere" \
    >"$home_dir/.copilot/session-state/88888888-8888-8888-8888-888888888888/events.jsonl"
  printf 'boss claude -\n*second claude -\nimpl codex manager\nscout codex -\ncop copilot -\ngem gemini -\nqw qwen -\nqw2 qwen -\n' \
    >"$work_dir/peon-code.conf"

  (
    cd "$work_dir"
    PATH="$fake_bin:$PATH" HOME="$home_dir" TMPDIR="$TEST_DIR" \
      FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=launch FAKE_TMUX_PANES=8 \
      "$ROOT/peon-code.sh" resume resume-test
  ) >"$TEST_DIR/resume.out" 2>"$TEST_DIR/resume.err" || true

  launch=$(grep -F 'buffer-content:claude' "$log")
  assert_contains <(printf '%s\n' "$launch") \
    "buffer-content:claude --resume 11111111-1111-1111-1111-111111111111"
  assert_contains <(printf '%s\n' "$launch") \
    "buffer-content:claude --resume 22222222-2222-2222-2222-222222222222"
  assert_contains "$log" "buffer-content:codex resume 33333333-3333-3333-3333-333333333333"
  assert_contains "$log" "buffer-content:copilot --resume=44444444-4444-4444-4444-444444444444 -i"
  assert_contains "$log" "buffer-content:gemini --resume 55555555-5555-5555-5555-555555555555 -i"
  assert_contains "$log" "buffer-content:qwen --resume 66666666-6666-6666-6666-666666666666 -i"
  assert_contains "$log" "buffer-content:qwen --resume mytag -i"
  assert_contains "$TEST_DIR/resume.err" "no earlier thread for scout"
  # A session name that is a prefix of another must not match its transcripts.
  assert_not_contains "$log" "99999999-9999-9999-9999-999999999999"
  # The copilot match from the other directory must not be resumed.
  assert_not_contains "$log" "88888888-8888-8888-8888-888888888888"
  # The nested sessionId in the gemini body must not be resumed.
  assert_not_contains "$log" "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
  # The *-marked agent (not the manager) is moved into the main slot of a
  # main-vertical layout, and the mark is stripped from its name.
  assert_contains "$log" "swap-pane -d -s %2 -t %1"
  assert_contains "$log" "select-layout -t resume-test:agents main-vertical"

  # Without a * mark, the first manager-role agent takes the main slot.
  : >"$log"
  printf 'boss claude -\nimpl codex manager\n' >"$work_dir/peon-code.conf"
  (
    cd "$work_dir"
    PATH="$fake_bin:$PATH" HOME="$home_dir" TMPDIR="$TEST_DIR" \
      FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=launch FAKE_TMUX_PANES=2 \
      "$ROOT/peon-code.sh" mgr-fallback
  ) >"$TEST_DIR/mgr.out" 2>"$TEST_DIR/mgr.err" || true
  assert_contains "$log" "swap-pane -d -s %2 -t %1"

  printf '*a claude -\n*b claude -\n' >"$work_dir/peon-code.conf"
  (
    cd "$work_dir"
    PATH="$fake_bin:$PATH" HOME="$home_dir" TMPDIR="$TEST_DIR" \
      FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=launch \
      "$ROOT/peon-code.sh" two-mains
  ) >"$TEST_DIR/two-mains.out" 2>"$TEST_DIR/two-mains.err" &&
    fail "a config with two main marks was accepted"
  assert_contains "$TEST_DIR/two-mains.err" "a second agent is marked main with *"
}

# The resume-summary picker is answered with Enter (its summary default);
# a pane already at the input line is left alone.
test_resume_picker_answered() {
  local fake_bin=$1 log="$TEST_DIR/picker.log" bin_dir="$TEST_DIR/picker-bin"
  mkdir -p "$bin_dir"
  cp "$fake_bin/sleep" "$bin_dir/sleep"
  cat >"$bin_dir/tmux" <<'FAKE_TMUX'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_TMUX_LOG"
case ${1:-} in
  capture-pane) printf '%s\n' "$FAKE_TMUX_CAPTURE" ;;
esac
FAKE_TMUX
  chmod +x "$bin_dir/tmux"

  : >"$log"
  FAKE_TMUX_LOG="$log" PATH="$bin_dir:$PATH" \
    FAKE_TMUX_CAPTURE='❯ 1. Resume from summary (recommended)' \
    bash -c 'source "$1/lib/tmux.sh"; answer_resume_picker %9' _ "$ROOT"
  assert_contains "$log" "send-keys -t %9 Enter"

  : >"$log"
  FAKE_TMUX_LOG="$log" PATH="$bin_dir:$PATH" \
    FAKE_TMUX_CAPTURE='❯ try "fix the tests"' \
    bash -c 'source "$1/lib/tmux.sh"; answer_resume_picker %9' _ "$ROOT"
  assert_not_contains "$log" "send-keys"
}

# One box measured from a synthetic capture: the capture's second row holds
# the box, the cursor sits on it, and the wanted text is what pane_box_text
# returns for it.
assert_box() {
  local what=$1 want=$2 cap=$3 got
  got=$(FAKE_TMUX_CAPTURE="$cap" PATH="$BOX_BIN:$PATH" \
    bash -c 'source "$1/lib/tmux.sh"; pane_box_text %9' _ "$ROOT") ||
    fail "pane_box_text failed on $what"
  [ "$got" = "$want" ] || fail "box for $what is '$got', expected '$want'"
}

# Text a TUI draws dim or in a gray foreground is a hint, not typed text, so
# a box holding only hints measures empty.
test_box_hint_text() {
  local bin_dir="$TEST_DIR/box-bin" e tail
  mkdir -p "$bin_dir"
  cat >"$bin_dir/tmux" <<'FAKE_TMUX'
#!/usr/bin/env bash
case ${1:-} in
  display) printf '1\n' ;;
  capture-pane) printf '%s\n' "$FAKE_TMUX_CAPTURE" ;;
esac
FAKE_TMUX
  chmod +x "$bin_dir/tmux"
  BOX_BIN=$bin_dir
  e=$(printf '\033')
  tail='
────'

  assert_box "a dim hint" "" "output line
❯ ${e}[2mTry \"fix the bug\"${e}[0m$tail"
  assert_box "a 256-color gray hint" "" "output line
❯ ${e}[38;5;242mTry \"fix the bug\"${e}[0m$tail"
  assert_box "a bright-black hint" "" "output line
❯ ${e}[90mTry \"fix the bug\"${e}[39m$tail"
  assert_box "dim combined with a gray foreground, reset bare" "" "output line
❯ ${e}[2;38;5;245mTry \"fix the bug\"${e}[m$tail"
  # The marker itself carries the hint style, and is still found.
  assert_box "a hint drawn over the marker" "" "output line
${e}[2m❯ Try \"fix the bug\"${e}[0m$tail"
  assert_box "styled but not hinted text" "hello world" "output line
❯ ${e}[1;38;5;39mhello world${e}[0m$tail"
  # The gray range ends at 249: 250 and above are near-white, which a theme
  # can use for ordinary text.
  assert_box "the last gray index" "" "output line
❯ ${e}[38;5;249mTry \"fix the bug\"${e}[0m$tail"
  assert_box "a near-white foreground" "hello world" "output line
❯ ${e}[38;5;250mhello world${e}[0m$tail"
  # A truecolor foreground is gray when its channels are near-equal, and
  # near-white or colored otherwise.
  assert_box "a truecolor gray hint" "" "output line
❯ ${e}[38;2;136;136;136mTry \"fix the bug\"${e}[0m$tail"
  assert_box "a truecolor near-white foreground" "hello world" "output line
❯ ${e}[38;2;250;250;250mhello world${e}[0m$tail"
  assert_box "a truecolor colored foreground" "hello world" "output line
❯ ${e}[38;2;200;120;40mhello world${e}[0m$tail"
  # Italic alone is not a hint style: CLIs draw ordinary text in it too.
  assert_box "an italic hint" "Try \"fix the bug\"" "output line
❯ ${e}[3mTry \"fix the bug\"${e}[0m$tail"
  assert_box "a white foreground" "hello world" "output line
❯ ${e}[38;5;255mhello world${e}[0m$tail"
  assert_box "typed text with a hint after it" "hello world" "output line
❯ hello world ${e}[2m(esc to clear)${e}[0m$tail"
  assert_box "plain typed text" "hello world" "output line
❯ hello world$tail"
  # A background or underline color carries sub-parameters of its own, which
  # are not attributes: reading them as attributes blanks real typed text.
  assert_box "a 256-color background" "hello world" "output line
❯ ${e}[48;5;90mhello world${e}[0m$tail"
  assert_box "a background whose index reads as dim" "hello world" "output line
❯ ${e}[48;5;2mhello world${e}[0m$tail"
  assert_box "a truecolor background" "hello world" "output line
❯ ${e}[48;2;38;5;242mhello world${e}[0m$tail"
  assert_box "an underline color" "hello world" "output line
❯ ${e}[58;5;2mhello world${e}[0m$tail"
  # An OSC 8 hyperlink: the URL is not text the box holds.
  assert_box "a hyperlink" "see docs" "output line
❯ ${e}]8;;https://ex.com${e}\\see${e}]8;;${e}\\ docs$tail"
  assert_box "a hyperlink ended with BEL" "see docs" "output line
❯ ${e}]8;;https://ex.com$(printf '\007')see${e}]8;;$(printf '\007') docs$tail"
}

# rebrief re-pastes the brief file stored in @peon_brief; a pane with no
# stored brief is skipped with a note, and sending none is an error.
test_rebrief() {
  local fake_bin=$1 log="$TEST_DIR/tmux-rebrief.log" home_dir="$TEST_DIR/home-rebrief"
  local paste_line enter_line
  local empty_box='output line
❯
────'
  local brief_box='output line
❯ You are boss, follow the rules.
────'
  local placeholder_box='output line
❯ [Pasted text #1 +15 lines]
────'
  mkdir -p "$home_dir"
  printf 'You are boss, follow the rules.\n' >"$TEST_DIR/rebrief-brief.md"

  : >"$log"
  PATH="$fake_bin:$PATH" HOME="$home_dir" FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=owned \
    FAKE_TMUX_BRIEF="$TEST_DIR/rebrief-brief.md" FAKE_TMUX_CAPTURE="$empty_box" \
    FAKE_TMUX_CAPTURE_AFTER="$brief_box" \
    "$ROOT/peon-code.sh" rebrief all owned >"$TEST_DIR/rebrief.out"
  assert_contains "$TEST_DIR/rebrief.out" "rebriefed 1 pane(s) in session owned"
  assert_contains "$log" "buffer-content:You are boss, follow the rules."
  # The Enter follows the paste, and only after a box read showed the brief.
  paste_line=$(grep -n -F -- "paste-buffer" "$log" | head -1 | cut -d: -f1)
  enter_line=$(grep -n -Fx -- "send-keys -t %1 Enter" "$log" | head -1 | cut -d: -f1)
  [ -n "$enter_line" ] || fail "rebrief pressed no Enter after the brief landed"
  [ "$enter_line" -gt "$paste_line" ] || fail "rebrief pressed Enter before pasting the brief"
  awk -v a="$paste_line" -v b="$enter_line" \
    'NR > a && NR < b && /^capture-pane/ { n++ } END { exit !(n + 0) }' "$log" ||
    fail "rebrief pressed Enter without reading the box after the paste"

  # A CLI that draws the brief as one paste placeholder row instead of its
  # text still gets its Enter.
  : >"$log"
  PATH="$fake_bin:$PATH" HOME="$home_dir" FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=owned \
    FAKE_TMUX_BRIEF="$TEST_DIR/rebrief-brief.md" FAKE_TMUX_CAPTURE="$empty_box" \
    FAKE_TMUX_CAPTURE_AFTER="$placeholder_box" \
    "$ROOT/peon-code.sh" rebrief all owned >"$TEST_DIR/rebrief-placeholder.out"
  assert_contains "$TEST_DIR/rebrief-placeholder.out" "rebriefed 1 pane(s) in session owned"
  assert_contains "$log" "send-keys -t %1 Enter"

  # A box that never shows the brief keeps the Enter back, so the pasted text
  # is left for the user to submit.
  : >"$log"
  if PATH="$fake_bin:$PATH" HOME="$home_dir" FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=owned \
    FAKE_TMUX_BRIEF="$TEST_DIR/rebrief-brief.md" FAKE_TMUX_CAPTURE="$empty_box" \
    "$ROOT/peon-code.sh" rebrief all owned >"$TEST_DIR/rebrief-unseen.out" 2>"$TEST_DIR/rebrief-unseen.err"; then
    fail "rebrief reported a brief its target never showed as sent"
  fi
  assert_contains "$TEST_DIR/rebrief-unseen.err" "no Enter sent to impl %1: the brief is in its box for the user to submit"
  assert_contains "$TEST_DIR/rebrief-unseen.err" "no brief sent in session owned"
  assert_contains "$log" "paste-buffer"
  assert_not_contains "$log" "send-keys"

  # An empty brief file paired with a dialog the paste opened: the dialog
  # measures the box empty, which must not count as the brief showing up.
  : >"$log"
  : >"$TEST_DIR/rebrief-empty.md"
  if PATH="$fake_bin:$PATH" HOME="$home_dir" FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=owned \
    FAKE_TMUX_BRIEF="$TEST_DIR/rebrief-empty.md" FAKE_TMUX_CAPTURE="$empty_box" \
    FAKE_TMUX_CAPTURE_AFTER='Do you trust this folder?
❯ 1. Yes, I trust this folder' \
    "$ROOT/peon-code.sh" rebrief all owned >"$TEST_DIR/rebrief-empty.out" 2>"$TEST_DIR/rebrief-empty.err"; then
    fail "rebrief answered a dialog with an empty brief"
  fi
  assert_not_contains "$log" "send-keys"

  # A pane in copy mode routes keys through the copy-mode table, so the Enter
  # is held back there too, even though the box shows the brief.
  : >"$log"
  if PATH="$fake_bin:$PATH" HOME="$home_dir" FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=owned \
    FAKE_TMUX_BRIEF="$TEST_DIR/rebrief-brief.md" FAKE_TMUX_CAPTURE="$empty_box" \
    FAKE_TMUX_CAPTURE_AFTER="$brief_box" FAKE_IN_MODE=1 \
    "$ROOT/peon-code.sh" rebrief all owned >"$TEST_DIR/rebrief-copy.out" 2>"$TEST_DIR/rebrief-copy.err"; then
    fail "rebrief pressed Enter on a pane in copy mode"
  fi
  assert_contains "$TEST_DIR/rebrief-copy.err" "no Enter sent to impl %1: the brief is in its box for the user to submit"
  assert_not_contains "$log" "send-keys"

  : >"$log"
  if PATH="$fake_bin:$PATH" HOME="$home_dir" FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=owned \
    "$ROOT/peon-code.sh" rebrief all owned >"$TEST_DIR/rebrief-none.out" 2>"$TEST_DIR/rebrief-none.err"; then
    fail "rebrief succeeded with no stored brief"
  fi
  assert_contains "$TEST_DIR/rebrief-none.err" "no stored brief for impl"

  : >"$log"
  if PATH="$fake_bin:$PATH" HOME="$home_dir" FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=owned \
    FAKE_TMUX_BRIEF="$TEST_DIR/rebrief-brief.md" FAKE_TMUX_CAPTURE="$empty_box" \
    FAKE_LOAD_BUFFER_EXIT=3 \
    "$ROOT/peon-code.sh" rebrief all owned >"$TEST_DIR/rebrief-fail.out" 2>"$TEST_DIR/rebrief-fail.err"; then
    fail "rebrief succeeded with a refused paste"
  fi
  assert_contains "$TEST_DIR/rebrief-fail.err" "no brief sent to impl %1: tmux refused the paste"
  assert_not_contains "$TEST_DIR/rebrief-fail.out" "rebriefed 1 pane(s)"
  assert_not_contains "$log" "paste-buffer"
  assert_not_contains "$log" "send-keys"

  : >"$log"
  if PATH="$fake_bin:$PATH" HOME="$home_dir" FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=owned \
    FAKE_TMUX_BRIEF="$TEST_DIR/rebrief-brief.md" FAKE_TMUX_CAPTURE='some other CLI
> ready' \
    "$ROOT/peon-code.sh" rebrief all owned >"$TEST_DIR/rebrief-bare.out" 2>"$TEST_DIR/rebrief-bare.err"; then
    fail "rebrief succeeded on a pane drawing no prompt marker"
  fi
  assert_contains "$TEST_DIR/rebrief-bare.err" "no brief sent to impl %1: it draws no prompt marker peon-code knows"
  assert_not_contains "$log" "load-buffer"
  assert_not_contains "$log" "paste-buffer"
}

# A fake tmux for the slash-command subcommands: it echoes back whatever was
# pasted into a pane until an Enter submits it.
write_slash_fake_tmux() {
  local bin_dir=$1 fake_bin=$2
  mkdir -p "$bin_dir"
  cp "$fake_bin/sleep" "$bin_dir/sleep"
  cat >"$bin_dir/tmux" <<'FAKE_TMUX'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_TMUX_LOG"
pane=%1
case "$*" in *%2*) pane=%2 ;; esac
box=$FAKE_BOX
[ "$pane" = %2 ] && box=$FAKE_BOX2
# A pane shows what was pasted into it once the paste has reached it, and
# empties the box again once an Enter submits it.
pastes=$(grep -c -- "-dpt $pane" "$FAKE_TMUX_LOG")
enters=$(grep -c -Fx -- "send-keys -t $pane Enter" "$FAKE_TMUX_LOG")
if [ "$pastes" -gt "$enters" ]; then
  box="output line
❯ $(grep -F 'buffer-content:' "$FAKE_TMUX_LOG" | tail -1 | cut -d: -f2-)
────"
fi
case ${1:-} in
  has-session) ;;
  show-options)
    case "$*" in
      *@peon_brief*) printf '%s\n' "${FAKE_TMUX_BRIEF:-}" ;;
      *) printf '1\n' ;;
    esac
    ;;
  list-panes) printf '%s\n' "${FAKE_PANES:-%1 node impl}" ;;
  display)
    case "$*" in
      *pane_in_mode*) printf '0\n' ;;
      *cursor_y*) printf '1\n' ;;
    esac
    ;;
  capture-pane)
    printf '%s\n' "$box"
    # A pane that keeps redrawing: every capture differs, so it never settles.
    [ -n "${FAKE_UNSETTLED:-}" ] && printf 'redrawing %s\n' "$(wc -l <"$FAKE_TMUX_LOG")"
    ;;
  load-buffer) printf 'buffer-content:%s\n' "$(cat)" >>"$FAKE_TMUX_LOG" ;;
  paste-buffer)
    # A pane named in FAKE_PASTE_FAIL refuses the paste.
    [ "$pane" = "${FAKE_PASTE_FAIL:-}" ] && exit 1
    ;;
esac
exit 0
FAKE_TMUX
  chmod +x "$bin_dir/tmux"
}

# compact pastes the /compact slash command with nothing around it, and only
# into a pane whose input box is empty.
test_compact() {
  local fake_bin=$1 log="$TEST_DIR/tmux-compact.log" bin_dir="$TEST_DIR/compact-bin"
  local empty_box busy_box menu_box brief="$TEST_DIR/compact-brief.md"
  local enter_line brief_line settle_reads
  write_slash_fake_tmux "$bin_dir" "$fake_bin"
  empty_box='output line
❯
────'
  busy_box='output line
❯ half a question
────'
  menu_box='Do you trust this folder?
❯ 1. Yes, I trust this folder
  2. No, exit'
  printf 'You are impl, follow the rules.\n' >"$brief"

  : >"$log"
  PATH="$bin_dir:$PATH" FAKE_TMUX_LOG="$log" FAKE_BOX="$empty_box" \
    FAKE_TMUX_BRIEF="$brief" \
    "$ROOT/peon-code.sh" compact all owned >"$TEST_DIR/compact.out"
  # No [from user] prefix and nothing else: a prefix stops the CLI from
  # reading the line as a slash command.
  grep -Fqx -- 'buffer-content:/compact' "$log" ||
    fail "compact pasted something other than /compact alone"
  assert_contains "$log" "send-keys -t %1 Enter"
  assert_contains "$TEST_DIR/compact.out" "sent /compact to 1 pane(s) in session owned"
  # The brief goes back in once the pane has settled, so the agent gets its
  # standing instructions after the compaction dropped them.
  assert_contains "$log" "buffer-content:You are impl, follow the rules."
  enter_line=$(grep -n -Fx -- 'send-keys -t %1 Enter' "$log" | head -1 | cut -d: -f1)
  brief_line=$(grep -n -F -- 'buffer-content:You are impl' "$log" | head -1 | cut -d: -f1)
  if [ -z "$enter_line" ] || [ "$brief_line" -le "$enter_line" ]; then
    fail "compact pasted the brief before submitting /compact"
  fi
  settle_reads=$(awk -v a="$enter_line" -v b="$brief_line" \
    'NR > a && NR < b && /^capture-pane/ { n++ } END { print n + 0 }' "$log")
  [ "$settle_reads" -ge 2 ] ||
    fail "compact made $settle_reads box reads between /compact and the brief, expected a settle wait"
  # One Enter submits /compact, the second submits the brief the pane shows.
  [ "$(grep -c -Fx -- 'send-keys -t %1 Enter' "$log")" = 2 ] ||
    fail "compact left the brief in the box instead of submitting it"

  : >"$log"
  if PATH="$bin_dir:$PATH" FAKE_TMUX_LOG="$log" FAKE_BOX="$busy_box" \
    "$ROOT/peon-code.sh" compact >"$TEST_DIR/compact-busy.out" 2>"$TEST_DIR/compact-busy.err"; then
    fail "compact pasted into a box holding typed text"
  fi
  assert_contains "$TEST_DIR/compact-busy.err" "its input box holds typed text"
  assert_not_contains "$log" "paste-buffer"
  assert_not_contains "$log" "send-keys"

  : >"$log"
  if PATH="$bin_dir:$PATH" FAKE_TMUX_LOG="$log" FAKE_BOX="$empty_box" \
    "$ROOT/peon-code.sh" compact nobody owned >"$TEST_DIR/compact-name.out" 2>"$TEST_DIR/compact-name.err"; then
    fail "compact accepted an unknown pane name"
  fi
  assert_contains "$TEST_DIR/compact-name.err" "no pane named nobody in session owned"
  assert_contains "$TEST_DIR/compact-name.err" "impl %1"
  assert_not_contains "$log" "paste-buffer"

  # Two panes, one free and one holding typed text: the free one is compacted
  # and the busy one is left as the user typed it.
  : >"$log"
  PATH="$bin_dir:$PATH" FAKE_TMUX_LOG="$log" FAKE_BOX="$empty_box" \
    FAKE_BOX2="$busy_box" FAKE_TMUX_BRIEF="$brief" \
    FAKE_PANES='%1 node impl
%2 node boss' \
    "$ROOT/peon-code.sh" compact all owned \
    >"$TEST_DIR/compact-partial.out" 2>"$TEST_DIR/compact-partial.err"
  assert_contains "$TEST_DIR/compact-partial.out" "sent /compact to 1 pane(s) in session owned"
  [ "$(grep -c -Fx -- 'buffer-content:/compact' "$log")" = 1 ] ||
    fail "compact pasted /compact more than once"
  assert_contains "$log" "send-keys -t %1 Enter"
  assert_not_contains "$log" "send-keys -t %2"
  assert_not_contains "$log" "-dpt %2"
  assert_contains "$TEST_DIR/compact-partial.err" "skipped %2: its input box holds typed text"
  # Only the compacted pane is rebriefed; the busy one is left as the user
  # typed it.
  [ "$(grep -c -F -- 'buffer-content:You are impl' "$log")" = 1 ] ||
    fail "compact pasted the brief into a pane it skipped"

  # Two panes, one taking the paste and one refusing it: the refusing pane is
  # reported and the run carries on through the rest.
  : >"$log"
  PATH="$bin_dir:$PATH" FAKE_TMUX_LOG="$log" FAKE_BOX="$empty_box" \
    FAKE_BOX2="$empty_box" FAKE_TMUX_BRIEF="$brief" FAKE_PASTE_FAIL=%2 \
    FAKE_PANES='%1 node impl
%2 node boss' \
    "$ROOT/peon-code.sh" compact all owned \
    >"$TEST_DIR/compact-refused.out" 2>"$TEST_DIR/compact-refused.err"
  assert_contains "$TEST_DIR/compact-refused.err" "skipped %2: tmux refused the paste"
  assert_contains "$TEST_DIR/compact-refused.out" "sent /compact to 1 pane(s) in session owned"
  assert_contains "$log" "send-keys -t %1 Enter"
  assert_not_contains "$log" "send-keys -t %2"
  # The pane that took /compact still gets its brief back.
  [ "$(grep -c -F -- 'buffer-content:You are impl' "$log")" = 1 ] ||
    fail "compact stopped before rebriefing the pane that took /compact"

  # A pane that keeps redrawing after /compact never settles, so its brief is
  # held back rather than pasted over whatever is on screen.
  : >"$log"
  PATH="$bin_dir:$PATH" FAKE_TMUX_LOG="$log" FAKE_BOX="$empty_box" \
    FAKE_TMUX_BRIEF="$brief" FAKE_UNSETTLED=1 \
    "$ROOT/peon-code.sh" compact all owned \
    >"$TEST_DIR/compact-busy-after.out" 2>"$TEST_DIR/compact-busy-after.err"
  assert_contains "$TEST_DIR/compact-busy-after.out" "sent /compact to 1 pane(s) in session owned"
  assert_contains "$TEST_DIR/compact-busy-after.err" "no brief sent to impl %1: it is still busy after /compact"
  assert_not_contains "$log" "buffer-content:You are impl"

  # A brief is held back from a box holding typed text, so text typed while a
  # pane compacted is left as the user typed it.
  : >"$log"
  if PATH="$bin_dir:$PATH" FAKE_TMUX_LOG="$log" FAKE_BOX="$busy_box" \
    FAKE_TMUX_BRIEF="$brief" \
    "$ROOT/peon-code.sh" rebrief all owned \
    >"$TEST_DIR/rebrief-typed.out" 2>"$TEST_DIR/rebrief-typed.err"; then
    fail "rebrief pasted into a box holding typed text"
  fi
  assert_contains "$TEST_DIR/rebrief-typed.err" "no brief sent to impl %1: its input box holds typed text"
  assert_not_contains "$log" "load-buffer"
  assert_not_contains "$log" "paste-buffer"
  assert_not_contains "$log" "send-keys"

  # A pane sitting on a menu measures an empty box, so only the menu itself
  # keeps the brief out; the Enter after a paste would answer the menu.
  : >"$log"
  if PATH="$bin_dir:$PATH" FAKE_TMUX_LOG="$log" FAKE_BOX="$menu_box" \
    FAKE_TMUX_BRIEF="$brief" \
    "$ROOT/peon-code.sh" rebrief all owned \
    >"$TEST_DIR/rebrief-menu.out" 2>"$TEST_DIR/rebrief-menu.err"; then
    fail "rebrief pasted into a pane on a menu"
  fi
  assert_contains "$TEST_DIR/rebrief-menu.err" \
    "no brief sent to impl %1: its input box holds typed text, or it is on a dialog or a menu"
  assert_not_contains "$log" "load-buffer"
  assert_not_contains "$log" "paste-buffer"
  assert_not_contains "$log" "send-keys"
}

# clear pastes the /clear slash command with nothing around it, and only into a
# pane whose input box is empty, then puts the brief back.
test_clear() {
  local fake_bin=$1 log="$TEST_DIR/tmux-clear.log" bin_dir="$TEST_DIR/clear-bin"
  local empty_box busy_box brief="$TEST_DIR/clear-brief.md"
  local enter_line brief_line
  write_slash_fake_tmux "$bin_dir" "$fake_bin"
  empty_box='output line
❯
────'
  busy_box='output line
❯ half a question
────'
  printf 'You are impl, follow the rules.\n' >"$brief"

  : >"$log"
  PATH="$bin_dir:$PATH" FAKE_TMUX_LOG="$log" FAKE_BOX="$empty_box" \
    FAKE_TMUX_BRIEF="$brief" \
    "$ROOT/peon-code.sh" clear all owned >"$TEST_DIR/clear.out"
  grep -Fqx -- 'buffer-content:/clear' "$log" ||
    fail "clear pasted something other than /clear alone"
  assert_not_contains "$log" "buffer-content:/compact"
  assert_contains "$log" "send-keys -t %1 Enter"
  assert_contains "$TEST_DIR/clear.out" "sent /clear to 1 pane(s) in session owned"
  # A cleared conversation has no brief left, so the brief goes back in once
  # the pane has settled.
  assert_contains "$log" "buffer-content:You are impl, follow the rules."
  enter_line=$(grep -n -Fx -- 'send-keys -t %1 Enter' "$log" | head -1 | cut -d: -f1)
  brief_line=$(grep -n -F -- 'buffer-content:You are impl' "$log" | head -1 | cut -d: -f1)
  if [ -z "$enter_line" ] || [ "$brief_line" -le "$enter_line" ]; then
    fail "clear pasted the brief before submitting /clear"
  fi
  # One Enter submits /clear, the second submits the brief the pane shows.
  [ "$(grep -c -Fx -- 'send-keys -t %1 Enter' "$log")" = 2 ] ||
    fail "clear left the brief in the box instead of submitting it"

  : >"$log"
  if PATH="$bin_dir:$PATH" FAKE_TMUX_LOG="$log" FAKE_BOX="$busy_box" \
    "$ROOT/peon-code.sh" clear >"$TEST_DIR/clear-busy.out" 2>"$TEST_DIR/clear-busy.err"; then
    fail "clear pasted into a box holding typed text"
  fi
  assert_contains "$TEST_DIR/clear-busy.err" "its input box holds typed text"
  assert_not_contains "$log" "paste-buffer"
  assert_not_contains "$log" "send-keys"

  : >"$log"
  if PATH="$bin_dir:$PATH" FAKE_TMUX_LOG="$log" FAKE_BOX="$empty_box" \
    "$ROOT/peon-code.sh" clear nobody owned >"$TEST_DIR/clear-name.out" 2>"$TEST_DIR/clear-name.err"; then
    fail "clear accepted an unknown pane name"
  fi
  assert_contains "$TEST_DIR/clear-name.err" "no pane named nobody in session owned"
  assert_not_contains "$log" "paste-buffer"

  # A pane that keeps redrawing after /clear never settles, so its brief is
  # held back rather than pasted over whatever is on screen.
  : >"$log"
  PATH="$bin_dir:$PATH" FAKE_TMUX_LOG="$log" FAKE_BOX="$empty_box" \
    FAKE_TMUX_BRIEF="$brief" FAKE_UNSETTLED=1 \
    "$ROOT/peon-code.sh" clear all owned \
    >"$TEST_DIR/clear-busy-after.out" 2>"$TEST_DIR/clear-busy-after.err"
  assert_contains "$TEST_DIR/clear-busy-after.out" "sent /clear to 1 pane(s) in session owned"
  assert_contains "$TEST_DIR/clear-busy-after.err" "no brief sent to impl %1: it is still busy after /clear"
  assert_not_contains "$log" "buffer-content:You are impl"
}

# compact and clear send to no pane at all when the calling pane is among
# the targets: sending to the others while the caller keeps its old context
# would leave the session out of sync.
test_slash_skips_all_when_caller_targeted() {
  local fake_bin=$1 log="$TEST_DIR/tmux-slash-self.log" bin_dir="$TEST_DIR/slash-self-bin"
  local empty_box brief="$TEST_DIR/slash-self-brief.md"
  write_slash_fake_tmux "$bin_dir" "$fake_bin"
  empty_box='output line
❯
────'
  printf 'You are impl, follow the rules.\n' >"$brief"

  # Two panes, one of them the caller: neither pane gets anything, and the
  # run still exits 0 with a warning on stderr.
  : >"$log"
  PATH="$bin_dir:$PATH" FAKE_TMUX_LOG="$log" FAKE_BOX="$empty_box" \
    FAKE_BOX2="$empty_box" FAKE_TMUX_BRIEF="$brief" \
    FAKE_PANES='%1 node impl
%2 node boss' \
    TMUX_PANE=%1 \
    "$ROOT/peon-code.sh" compact all owned \
    >"$TEST_DIR/slash-self.out" 2>"$TEST_DIR/slash-self.err" ||
    fail "compact exited nonzero when the calling pane was a target"
  assert_contains "$TEST_DIR/slash-self.err" \
    "not sending /compact: the calling pane is a target; run this command from a shell or another pane instead"
  assert_not_contains "$TEST_DIR/slash-self.out" "sent /compact"
  assert_not_contains "$log" "paste-buffer"
  assert_not_contains "$log" "load-buffer"
  assert_not_contains "$log" "send-keys -t %1"
  assert_not_contains "$log" "send-keys -t %2"

  # A single pane that is also the caller: same all-or-nothing skip.
  : >"$log"
  PATH="$bin_dir:$PATH" FAKE_TMUX_LOG="$log" FAKE_BOX="$empty_box" \
    FAKE_TMUX_BRIEF="$brief" TMUX_PANE=%1 \
    "$ROOT/peon-code.sh" clear all owned \
    >"$TEST_DIR/slash-self-only.out" 2>"$TEST_DIR/slash-self-only.err" ||
    fail "clear exited nonzero when the only match was the calling pane"
  assert_contains "$TEST_DIR/slash-self-only.err" \
    "not sending /clear: the calling pane is a target; run this command from a shell or another pane instead"
  assert_not_contains "$log" "paste-buffer"
  assert_not_contains "$log" "load-buffer"
}

# msg presses Enter into a pane only once that pane's box shows the message,
# and one pane that never shows it does not hold up the others.
test_msg() {
  local fake_bin=$1 log="$TEST_DIR/tmux-msg.log" bin_dir="$TEST_DIR/msg-bin"
  local paste_line enter_line
  mkdir -p "$bin_dir"
  cp "$fake_bin/sleep" "$bin_dir/sleep"
  cat >"$bin_dir/tmux" <<'FAKE_TMUX'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"$FAKE_TMUX_LOG"
pane=%1
case "$*" in *%2*) pane=%2 ;; esac
# tmux refuses the paste for a pane named in FAKE_REFUSE.
case " ${FAKE_REFUSE:-} " in
  *" $pane "*) case ${1:-} in paste-buffer) exit 1 ;; esac ;;
esac
box='output line
❯
────'
# A pane shows what was pasted into it once the paste has reached it, except a
# pane named in FAKE_BLIND, whose box never shows the paste.
case " ${FAKE_BLIND:-} " in
  *" $pane "*) ;;
  *)
    if grep -Fq -- "-dpt $pane" "$FAKE_TMUX_LOG"; then
      box="output line
❯ $(grep -F 'buffer-content:' "$FAKE_TMUX_LOG" | tail -1 | cut -d: -f2-)
────"
    fi
    ;;
esac
case ${1:-} in
  has-session) ;;
  show-options) printf '1\n' ;;
  list-panes) printf '%s\n' "${FAKE_PANES:-%1 node impl}" ;;
  display)
    case "$*" in
      *pane_in_mode*) printf '%s\n' "${FAKE_IN_MODE:-0}" ;;
      *cursor_y*) printf '1\n' ;;
    esac
    ;;
  capture-pane) printf '%s\n' "$box" ;;
  load-buffer) printf 'buffer-content:%s\n' "$(cat)" >>"$FAKE_TMUX_LOG" ;;
esac
exit 0
FAKE_TMUX
  chmod +x "$bin_dir/tmux"

  : >"$log"
  PATH="$bin_dir:$PATH" FAKE_TMUX_LOG="$log" \
    FAKE_PANES='%1 node impl
%2 node boss' \
    "$ROOT/peon-code.sh" msg all hello owned >"$TEST_DIR/msg-all.out" 2>"$TEST_DIR/msg-all.err"
  assert_contains "$TEST_DIR/msg-all.out" "sent to 2 pane(s) in session owned"
  assert_contains "$log" "buffer-content:[from user] hello"
  assert_contains "$log" "send-keys -t %2 Enter"
  # The Enter follows the paste, and only after a box read showed the message.
  paste_line=$(grep -n -F -- "-dpt %1" "$log" | head -1 | cut -d: -f1)
  enter_line=$(grep -n -Fx -- "send-keys -t %1 Enter" "$log" | head -1 | cut -d: -f1)
  [ -n "$enter_line" ] || fail "msg pressed no Enter after the message landed"
  [ "$enter_line" -gt "$paste_line" ] || fail "msg pressed Enter before pasting the message"
  awk -v a="$paste_line" -v b="$enter_line" \
    'NR > a && NR < b && /^capture-pane/ { n++ } END { exit !(n + 0) }' "$log" ||
    fail "msg pressed Enter without reading the box after the paste"

  # One pane whose box never shows the message: it keeps its Enter back and is
  # reported, and the other pane still gets its message submitted.
  : >"$log"
  if PATH="$bin_dir:$PATH" FAKE_TMUX_LOG="$log" FAKE_BLIND=%2 \
    FAKE_PANES='%1 node impl
%2 node boss' \
    "$ROOT/peon-code.sh" msg all hello owned \
    >"$TEST_DIR/msg-blind.out" 2>"$TEST_DIR/msg-blind.err"; then
    fail "msg reported a message its target never showed as delivered"
  fi
  assert_contains "$TEST_DIR/msg-blind.out" "sent to 1 pane(s) in session owned"
  assert_contains "$TEST_DIR/msg-blind.err" \
    "no Enter sent to boss %2: the message is in its box for you to submit"
  assert_contains "$TEST_DIR/msg-blind.err" "1 message(s) were not delivered in session owned"
  assert_contains "$log" "send-keys -t %1 Enter"
  assert_not_contains "$log" "send-keys -t %2"

  # A pane tmux refuses the paste for takes no message and is reported, and the
  # other pane still gets its own.
  : >"$log"
  if PATH="$bin_dir:$PATH" FAKE_TMUX_LOG="$log" FAKE_REFUSE=%2 \
    FAKE_PANES='%1 node impl
%2 node boss' \
    "$ROOT/peon-code.sh" msg all hello owned \
    >"$TEST_DIR/msg-refused.out" 2>"$TEST_DIR/msg-refused.err"; then
    fail "msg reported a message tmux refused as delivered"
  fi
  assert_contains "$TEST_DIR/msg-refused.out" "sent to 1 pane(s) in session owned"
  assert_contains "$TEST_DIR/msg-refused.err" \
    "no message sent to boss %2: tmux refused the paste"
  assert_contains "$log" "send-keys -t %1 Enter"
  assert_not_contains "$log" "send-keys -t %2"

  # A pane in copy mode routes an Enter through the copy-mode key table, so the
  # message is left in its box instead.
  : >"$log"
  if PATH="$bin_dir:$PATH" FAKE_TMUX_LOG="$log" FAKE_IN_MODE=1 \
    "$ROOT/peon-code.sh" msg all hello owned \
    >"$TEST_DIR/msg-copy.out" 2>"$TEST_DIR/msg-copy.err"; then
    fail "msg reported a message its target never showed as delivered"
  fi
  assert_contains "$TEST_DIR/msg-copy.out" "sent to 0 pane(s) in session owned"
  assert_contains "$TEST_DIR/msg-copy.err" \
    "no Enter sent to impl %1: the message is in its box for you to submit"
  assert_contains "$TEST_DIR/msg-copy.err" "no message sent in session owned"
  assert_not_contains "$log" "send-keys"
}

bash -n "$ROOT/peon-code.sh" "$ROOT/lib/config.sh" "$ROOT/lib/tmux.sh" \
  "$ROOT/install.sh"
fake_bin=$(make_fake_commands)
test_install_guard
test_session_ownership "$fake_bin"
test_unique_buffers_and_launch_failure "$fake_bin"
test_launch_with_prompt_box "$fake_bin"
test_config_loading "$fake_bin"
test_brief_rule7_variants "$fake_bin"
test_git_deny_settings "$fake_bin"
test_git_deny_unstarred_main "$fake_bin"
SEND_BIN=$(make_send_bin "$fake_bin")
test_send_refuses
test_send_delivers
test_resume_picks_each_agent_thread "$fake_bin"
test_resume_picker_answered "$fake_bin"
test_box_hint_text
test_rebrief "$fake_bin"
test_compact "$fake_bin"
test_clear "$fake_bin"
test_slash_skips_all_when_caller_targeted "$fake_bin"
test_msg "$fake_bin"
echo "tests: PASS"
