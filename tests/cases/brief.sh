#!/usr/bin/env bash
set -euo pipefail
CASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/helpers.sh
. "$CASE_DIR/../helpers.sh"

# Rule 9 tells every pane to run independent tasks at the same time.
test_brief_rule9_parallel() {
  local fake_bin=$1 log="$TEST_DIR/tmux-rule9.log" home_dir="$TEST_DIR/home-rule9"
  local work_dir="$TEST_DIR/rule9-work" line boss_brief helper_brief
  local rule9="10. Parallel work: independent tasks run at the same time, not one after another."
  local claim_rule="Claim every open task assigned to you whose files do not overlap what you or any other agent already claimed"
  local git_rule="Any subagent you spawn gets git read-only in its prompt: never checkout, restore, reset, clean, stash"
  local serial_rule="Tasks touching the same files still run one at a time"
  local signal_rule="Never signal a pid list computed from a ps or awk walk, and never send STOP, TERM, or KILL to any process you did not start"
  local scope_rule="start it as setsid systemd-run --user --scope -q -p OOMPolicy=continue <cmd>: tmux runs each pane in a systemd scope whose default policy stops the whole pane"
  mkdir -p "$home_dir" "$work_dir"
  printf '*boss ./missing-agent -\nhelper ./missing-agent -\n' >"$work_dir/peon-code.conf"

  (
    cd "$work_dir"
    PATH="$fake_bin:$PATH" HOME="$home_dir" TMPDIR="$TEST_DIR" \
      FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=launch FAKE_TMUX_PANES=2 \
      "$ROOT/peon-code.sh" -c "$work_dir/peon-code.conf" rule9-test
  ) >"$TEST_DIR/rule9.out" 2>"$TEST_DIR/rule9.err" </dev/null || true

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
  assert_contains "$boss_brief" "$signal_rule"
  assert_contains "$boss_brief" "$scope_rule"
  assert_contains "$helper_brief" "$rule9"
  assert_contains "$helper_brief" "$claim_rule"
  assert_contains "$helper_brief" "$git_rule"
  assert_contains "$helper_brief" "$serial_rule"
  assert_contains "$helper_brief" "$signal_rule"
  assert_contains "$helper_brief" "$scope_rule"
}

# Rule 7 differs by pane: the main pane's brief carries the manager
# verification sentence too, every other pane gets the worker sentence alone.
test_brief_rule7_variants() {
  local fake_bin=$1 log="$TEST_DIR/tmux-rule7.log" home_dir="$TEST_DIR/home-rule7"
  local work_dir="$TEST_DIR/rule7-work" line boss_brief helper_brief
  local worker_rule="7. Task completion: set your board row to done before you send the completion message. A task is not done until its row says done; a message never substitutes for the row edit. Send the completion message to the manager and, when the team has a reviewer, to the reviewer as well: an agent acts only when a message reaches its pane, a board edit alone wakes nobody."
  local reviewer_rule='Send the completion message to the manager and, when the team has a reviewer, to the reviewer as well'
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
  ) >"$TEST_DIR/rule7.out" 2>"$TEST_DIR/rule7.err" </dev/null || true

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
  assert_contains "$boss_brief" "$reviewer_rule"
  assert_contains "$helper_brief" "$reviewer_rule"
  assert_not_contains "$helper_brief" "$manager_rule"
  assert_not_contains "$helper_brief" "$delete_rule"
  assert_not_contains "$helper_brief" "$dispatch_rule"
}

test_brief_role_rules() (
  local SCRIPT_DIR=$ROOT TASK_BOARD="$TEST_DIR/solo-task.md" SESSION=solo N=3 MAIN=0 ROSTER='' GIT_DENY_PROSE=commit
  local NAMES=(boss impl check) CMDS=(claude codex claude) PANE_IDS=(%10 %11 %12)
  local ROLES=("$ROOT/roles/manager.md" "$ROOT/roles/implementer.md" "$ROOT/roles/reviewer.md")
  local TEAMS=(solo solo solo) TEAM_NAMES=(solo) i brief
  # shellcheck source=lib/config.sh
  source "$ROOT/lib/config.sh"
  # shellcheck source=lib/brief.sh
  source "$ROOT/lib/brief.sh"
  for i in "${!NAMES[@]}"; do
    brief="$TEST_DIR/solo-$i.md"
    build_brief "$i" >"$brief"
    seed_board "$i"
    [ "$(cat "$TASK_BOARD")" = "$BOARD_HEADER" ] || fail 'single team received a director board header'
    assert_contains "$brief" 'edit only the cells your type owns: a worker its own rows, the reviewer the status cell of a row it reviewed, the manager a done repair, the deletion, and the removal of a row it re-splits or reassigns after a blocked message; never rewrite the rest of the file'
    assert_not_contains "$brief" 'Every task cell starts with the plan row id it serves, like D2: rename parser.'
    assert_not_contains "$TASK_BOARD" 'Every task cell starts with the plan row id it serves, like D2: rename parser.'
    assert_not_contains "$brief" 'Only the director edits this file; the manager named in who reports its row by message.'
    assert_contains "$brief" 'That agent splits the work onto the task board and assigns it; every other agent waits for a board entry or a message instead of inventing work at launch.'
    assert_contains "$brief" 'do not resend; tell the user.'
    assert_contains "$brief" 'only when no recipient is reachable, tell the user.'
    assert_contains "$brief" 'proceed on your best judgment or tell the user.'
    assert_contains "$brief" 'id is T1, T2, ...'
    assert_not_contains "$brief" 'You are in team'
    if [ "$i" -eq 0 ]; then
      assert_not_contains "$brief" 'Claim every open task assigned to you'
    else
      assert_contains "$brief" 'Claim every open task assigned to you'
    fi
  done
  NAMES[3]=director
  CMDS[3]=claude
  PANE_IDS[3]=%13
  ROLES[1]=''
  MAIN=3 N=4
  build_brief 1 >"$brief"
  assert_contains "$brief" 'do not resend; tell the director.'
  assert_contains "$brief" 'only when no recipient is reachable, tell the director.'
  assert_contains "$brief" 'proceed on your best judgment or tell the director.'
  assert_not_contains "$brief" 'tell your team manager.'
)

fake_bin=$(make_fake_commands)
test_brief_rule9_parallel "$fake_bin"
test_brief_rule7_variants "$fake_bin"
test_brief_role_rules
echo "brief: PASS"
