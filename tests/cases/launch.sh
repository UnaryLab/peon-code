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
  (
    cd "$TEST_DIR"
    HOME="$home_dir" "$bin_dir/peon-code" -h
  ) >"$TEST_DIR/installed-help.out"
  assert_contains "$TEST_DIR/installed-help.out" "peon-code.sh [-c file]"
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
  # The board row is the claim: no start message, alerts name the row id,
  # scrapes stop at 100 lines, and the header rules ride inside the brief's
  # recreate instruction.
  assert_contains "$brief_file" "tmux capture-pane -pt <other-pane-id> -S -100"
  assert_not_contains "$brief_file" "you start a task, to claim the files you will touch"
  assert_contains "$brief_file" "The board row is the claim, so starting a task sends no message."
  assert_contains "$brief_file" "an alert is one line naming the row id"
  assert_contains "$brief_file" "Its header states the row format, the id rule, and the status rules"
  assert_contains "$brief_file" "| id | who | task | files | status |"
  assert_contains "$brief_file" "a status change overwrites the cell, never appends to it"
  assert_contains "$brief_file" "never delay a status change to collect a batch"
  # The seeded board opens with the same rules header the brief embeds.
  assert_contains "$work_dir/.peon-code-task.md" "| id | who | task | files | status |"
  assert_contains "$work_dir/.peon-code-task.md" "a status change overwrites the cell, never appends to it"
  assert_contains "$work_dir/.peon-code-task.md" "never reused, even after the row is deleted"
  assert_not_contains "$brief_file" "tmux send-keys -t <other-pane-id> -l"
  # The message goes in on stdin, so nothing asks agents to mind their quoting.
  assert_not_contains "$brief_file" "Avoid single quotes"
}

# Rule 9 tells every pane to run independent tasks at the same time.
test_brief_rule9_parallel() {
  local fake_bin=$1 log="$TEST_DIR/tmux-rule9.log" home_dir="$TEST_DIR/home-rule9"
  local work_dir="$TEST_DIR/rule9-work" line boss_brief helper_brief
  local rule9="10. Parallel work: independent tasks run at the same time, not one after another."
  local claim_rule="Claim every open task assigned to you whose files do not overlap what you or any other agent already claimed"
  local git_rule="Any subagent you spawn gets git read-only in its prompt: never checkout, restore, reset, clean, stash"
  local serial_rule="Tasks touching the same files still run one at a time"
  mkdir -p "$home_dir" "$work_dir"
  printf '*boss ./missing-agent -\nhelper ./missing-agent -\n' >"$work_dir/peon-code.conf"

  (
    cd "$work_dir"
    PATH="$fake_bin:$PATH" HOME="$home_dir" TMPDIR="$TEST_DIR" \
      FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=launch FAKE_TMUX_PANES=2 \
      "$ROOT/peon-code.sh" -c "$work_dir/peon-code.conf" rule9-test
  ) >"$TEST_DIR/rule9.out" 2>"$TEST_DIR/rule9.err" || true

  line=$(grep -F "buffer-content:" "$log" | sed -n '1p')
  boss_brief=${line#*"\$(cat "}
  boss_brief=${boss_brief%%')"'*}
  line=$(grep -F "buffer-content:" "$log" | sed -n '2p')
  helper_brief=${line#*"\$(cat "}
  helper_brief=${helper_brief%%')"'*}
  [ -n "$boss_brief" ] || fail "rule9 test did not record the main pane's brief file"
  [ -n "$helper_brief" ] || fail "rule9 test did not record the other pane's brief file"

  assert_contains "$boss_brief" "$rule9"
  assert_contains "$boss_brief" "$claim_rule"
  assert_contains "$boss_brief" "$git_rule"
  assert_contains "$boss_brief" "$serial_rule"
  assert_contains "$helper_brief" "$rule9"
  assert_contains "$helper_brief" "$claim_rule"
  assert_contains "$helper_brief" "$git_rule"
  assert_contains "$helper_brief" "$serial_rule"
}

# Rule 7 differs by pane: the main pane's brief carries the manager
# verification sentence too, every other pane gets the worker sentence alone.
test_brief_rule7_variants() {
  local fake_bin=$1 log="$TEST_DIR/tmux-rule7.log" home_dir="$TEST_DIR/home-rule7"
  local work_dir="$TEST_DIR/rule7-work" line boss_brief helper_brief
  local worker_rule="7. Task completion: set your board row to done before you send the completion message. A task is not done until its row says done; a message never substitutes for the row edit."
  local manager_rule="On receiving a completion message, verify the sender's board row is done and set it to done yourself if it is not, before acknowledging the work or dispatching new work; if the row already reads reviewed pass or reviewed fail, leave that status as the reviewer wrote it rather than setting it to done, and when it still reads reviewed fail, message the author to finish the rework."
  local delete_rule="Once the work is verified, delete the row from the board, but only after the reviewer records a verdict on it if the team has one; the board lists only open work, and the deletion is the acknowledgment, so message a worker only to assign, reassign, request rework, or unblock."
  local dispatch_rule="When you dispatch, send each agent one message listing all its row ids rather than one message per row, never delaying a ready dispatch to collect a batch."
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

  assert_contains "$boss_brief" "$worker_rule $manager_rule $delete_rule $dispatch_rule"
  assert_contains "$helper_brief" "$worker_rule"
  assert_not_contains "$helper_brief" "$manager_rule"
  assert_not_contains "$helper_brief" "$delete_rule"
  assert_not_contains "$helper_brief" "$dispatch_rule"
}

fake_bin=$(make_fake_commands)
test_install_guard
test_session_ownership "$fake_bin"
test_unique_buffers_and_launch_failure "$fake_bin"
test_launch_with_prompt_box "$fake_bin"
test_config_loading "$fake_bin"
test_brief_rule7_variants "$fake_bin"
test_brief_rule9_parallel "$fake_bin"
echo "launch: PASS"
