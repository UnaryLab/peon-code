#!/usr/bin/env bash
set -euo pipefail
CASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/helpers.sh
. "$CASE_DIR/../helpers.sh"

test_config_loading() {
  local fake_bin=$1 log="$TEST_DIR/tmux-config.log" home_dir="$TEST_DIR/home-config"
  local config_dir="$TEST_DIR/config" work_dir="$TEST_DIR/config-work" line brief_file
  mkdir -p "$home_dir" "$config_dir" "$work_dir"
  printf -- '---\ntype: worker\ndescription: a custom worker\n---\nKeep changes focused.\n' >"$config_dir/custom.md"
  printf 'lead ./missing-agent manager\ncheck ./missing-agent reviewer\nboss ./missing-agent ./custom.md\n' >"$config_dir/team.conf"

  (
    cd "$work_dir"
    PATH="$fake_bin:$PATH" HOME="$home_dir" TMPDIR="$TEST_DIR" \
      FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=launch FAKE_TMUX_PANES=3 \
      "$ROOT/peon-code.sh" -c "$config_dir/team.conf" config-test
  ) >"$TEST_DIR/config.out" 2>"$TEST_DIR/config.err" </dev/null &&
    fail "a config launch with a dead agent succeeded"
  assert_contains "$TEST_DIR/config.err" "agents failed to start; killed session config-test: lead check boss"
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
  assert_contains "$brief_file" "3. Held sends: when send gives up on a blocked target"
  # A message never substitutes for closing the board row.
  assert_contains "$brief_file" "7. Task completion and messaging: follow the team protocol above for your type"
  # The board row is the claim: no start message, alerts name the row id,
  # scrapes stop at 100 lines, and the header rules ride inside the brief's
  # recreate instruction.
  assert_contains "$brief_file" "tmux capture-pane -pt <other-pane-id> -S -100"
  assert_not_contains "$brief_file" "you start a task, to claim the files you will touch"
  assert_contains "$brief_file" "The row is the claim: a worker writes its row"
  assert_not_contains "$brief_file" "Message another agent only when"
  assert_not_contains "$brief_file" "Record your claim on the board before you start"
  assert_contains "$brief_file" "then one line naming the row id"
  assert_contains "$brief_file" "Its header states the row format, the id rule, and the status rules"
  assert_contains "$brief_file" "| id | who | task | files | status |"
  assert_contains "$brief_file" "a status change overwrites the cell, never appends to it"
  assert_contains "$brief_file" "a status change never waits to collect a batch"
  # The seeded board opens with the same rules header the brief embeds.
  assert_contains "$work_dir/.peon-code-task.md" "| id | who | task | files | status |"
  assert_contains "$work_dir/.peon-code-task.md" "a status change overwrites the cell, never appends to it"
  assert_contains "$work_dir/.peon-code-task.md" "never reused, even after the row is deleted"
  assert_not_contains "$brief_file" "tmux send-keys -t <other-pane-id> -l"
  # The message goes in on stdin, so nothing asks agents to mind their quoting.
  assert_not_contains "$brief_file" "Avoid single quotes"
}

# Every role the README lists as shipped resolves to a file, and every worker
# role records completion on its row before it messages.
test_shipped_roles() {
  local role
  for role in $(sed -n 's/^Shipped roles: //p' "$ROOT/README.md" | tr -d '`,.'); do
    [ -f "$ROOT/roles/$role.md" ] || fail "README lists an unshipped role: $role"
  done
  # Every shipped role carries a type, and the protocol file, which is not a
  # role, holds the board and message rules once: no role restates them.
  for role in manager implementer writer reviewer; do
    case $(sed -n '2,/^---$/p' "$ROOT/roles/$role.md" | sed -n 's/^type:[[:space:]]*//p') in
      manager|worker|reviewer) ;;
      *) fail "roles/$role.md has no frontmatter type" ;;
    esac
    assert_not_contains "$ROOT/roles/$role.md" "when the team has a reviewer"
    assert_not_contains "$ROOT/roles/$role.md" "T3 done"
  done
  assert_contains "$ROOT/roles/protocol.md" "| done | worker | manager and reviewer |"
  assert_contains "$ROOT/roles/protocol.md" "Set the row to done first, then send the done message"
  assert_contains "$ROOT/roles/protocol.md" "Once the reviewer records reviewed pass on a row, delete it"
  assert_contains "$ROOT/roles/protocol.md" "A row that documents or describes another row's change is not independent either"
  # The reviewer judges a write-up on its output file, since a new file
  # shows in no diff, and verifies the citations instead of running a check.
  assert_contains "$ROOT/roles/reviewer.md" "a new file shows in no diff, so read it directly"
  assert_contains "$ROOT/roles/reviewer.md" "every cited path and line exists and says what the write-up claims"
  assert_contains "$ROOT/roles/reviewer.md" "four labeled segments in order (Problem, Importance, Innovation, Implementation)"
  assert_contains "$ROOT/roles/writer.md" "four labeled segments in this order"
}

# A role pane's brief carries the role body without its frontmatter and the
# protocol once, with rule 7 pointing at it; a role file without a type
# aborts the launch; a custom role path typed manager becomes the main pane.
test_role_frontmatter() {
  local fake_bin=$1 home_dir="$TEST_DIR/home-frontmatter" config_dir="$TEST_DIR/frontmatter-config"
  local work_dir="$TEST_DIR/frontmatter-work" log="$TEST_DIR/tmux-frontmatter.log"
  local line lead_brief helper_brief
  mkdir -p "$home_dir" "$config_dir" "$work_dir"
  printf -- '---\ntype: manager\ndescription: a custom lead\n---\nLead body line.\n' >"$config_dir/lead.md"
  printf 'helper ./missing-agent implementer\ncheck ./missing-agent reviewer\nlead ./missing-agent ./lead.md\n' >"$config_dir/team.conf"
  (
    cd "$work_dir"
    PATH="$fake_bin:$PATH" HOME="$home_dir" TMPDIR="$TEST_DIR" \
      FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=launch FAKE_TMUX_PANES=3 \
      "$ROOT/peon-code.sh" -c "$config_dir/team.conf" frontmatter-test
  ) >"$TEST_DIR/frontmatter.out" 2>"$TEST_DIR/frontmatter.err" </dev/null || true

  line=$(grep -F "buffer-content:" "$log" | sed -n '1p')
  helper_brief=${line#*"\$(cat "}
  helper_brief=${helper_brief%%')"'*}
  line=$(grep -F "buffer-content:" "$log" | sed -n '3p')
  lead_brief=${line#*"\$(cat "}
  lead_brief=${lead_brief%%')"'*}
  [ -f "$lead_brief" ] || fail "frontmatter test did not record both briefs"
  # The unstarred manager-type role is main: it carries no git prohibition.
  assert_not_contains "$lead_brief" "Hard prohibition for this pane"
  assert_contains "$helper_brief" "Hard prohibition for this pane"
  assert_contains "$lead_brief" "Your role: lead, type manager: a custom lead"
  assert_contains "$lead_brief" "Lead body line."
  assert_not_contains "$lead_brief" "description: a custom lead"
  assert_contains "$lead_brief" "pane %3: lead (./missing-agent) - lead (manager): a custom lead"
  assert_contains "$helper_brief" "Your role: implementer, type worker: edits code to meet a task"
  assert_contains "$helper_brief" "7. Task completion and messaging: follow the team protocol above for your type"
  # The protocol rides once, sliced to the pane's own duties section.
  [ "$(grep -c -F "## Worker duties" "$helper_brief")" = 1 ] || fail "the brief does not carry the protocol exactly once"
  assert_contains "$helper_brief" "## Messages"
  assert_not_contains "$helper_brief" "## Manager duties"
  assert_not_contains "$helper_brief" "## Reviewer duties"
  assert_contains "$lead_brief" "## Manager duties"
  assert_not_contains "$lead_brief" "## Worker duties"

  printf -- 'No frontmatter here.\n' >"$config_dir/untyped.md"
  printf 'solo ./missing-agent ./untyped.md\n' >"$config_dir/team.conf"
  if (
    cd "$work_dir"
    PATH="$fake_bin:$PATH" HOME="$home_dir" TMPDIR="$TEST_DIR" \
      FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=launch FAKE_TMUX_PANES=1 \
      "$ROOT/peon-code.sh" -c "$config_dir/team.conf" untyped-test
  ) >"$TEST_DIR/untyped.out" 2>"$TEST_DIR/untyped.err" </dev/null; then
    fail "a role file without a type launched"
  fi
  assert_contains "$TEST_DIR/untyped.err" "needs a frontmatter type: manager, worker, or reviewer"

  # A manager, a worker, and a reviewer are all required once any pane has a role.
  printf 'lead ./missing-agent manager\ncheck ./missing-agent reviewer\n' >"$config_dir/team.conf"
  if (
    cd "$work_dir"
    PATH="$fake_bin:$PATH" HOME="$home_dir" TMPDIR="$TEST_DIR" \
      FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=launch FAKE_TMUX_PANES=2 \
      "$ROOT/peon-code.sh" -c "$config_dir/team.conf" no-worker-test
  ) >"$TEST_DIR/no-worker.out" 2>"$TEST_DIR/no-worker.err" </dev/null; then
    fail "a team with no worker launched"
  fi
  assert_contains "$TEST_DIR/no-worker.err" "needs a worker-type role"
  printf 'impl ./missing-agent implementer\ncheck ./missing-agent reviewer\n' >"$config_dir/team.conf"
  if (
    cd "$work_dir"
    PATH="$fake_bin:$PATH" HOME="$home_dir" TMPDIR="$TEST_DIR" \
      FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=launch FAKE_TMUX_PANES=2 \
      "$ROOT/peon-code.sh" -c "$config_dir/team.conf" no-manager-test
  ) >"$TEST_DIR/no-manager.out" 2>"$TEST_DIR/no-manager.err" </dev/null; then
    fail "a team with no manager launched"
  fi
  assert_contains "$TEST_DIR/no-manager.err" "needs a manager-type role"
  printf 'lead ./missing-agent manager\nimpl ./missing-agent implementer\n' >"$config_dir/team.conf"
  if (
    cd "$work_dir"
    PATH="$fake_bin:$PATH" HOME="$home_dir" TMPDIR="$TEST_DIR" \
      FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=launch FAKE_TMUX_PANES=2 \
      "$ROOT/peon-code.sh" -c "$config_dir/team.conf" no-reviewer-test
  ) >"$TEST_DIR/no-reviewer.out" 2>"$TEST_DIR/no-reviewer.err" </dev/null; then
    fail "a team with no reviewer launched"
  fi
  assert_contains "$TEST_DIR/no-reviewer.err" "needs a reviewer-type role"
}

# A team with a writer lists its output directory in .gitignore once; a
# team without one leaves .gitignore alone.
test_writer_gitignore() {
  local fake_bin=$1 home_dir="$TEST_DIR/home-writer" config_dir="$TEST_DIR/writer-config"
  local work_dir="$TEST_DIR/writer-work" log="$TEST_DIR/tmux-writer.log" n
  mkdir -p "$home_dir" "$config_dir" "$work_dir"
  printf 'lead ./missing-agent manager\ncheck ./missing-agent reviewer\nboss ./missing-agent writer\n' >"$config_dir/team.conf"
  git -C "$work_dir" init -q
  printf '*.log' >"$work_dir/.gitignore"
  for n in 1 2; do
    (
      cd "$work_dir"
      PATH="$fake_bin:$PATH" HOME="$home_dir" TMPDIR="$TEST_DIR" \
        FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=launch FAKE_TMUX_PANES=3 \
        "$ROOT/peon-code.sh" -c "$config_dir/team.conf" "writer-test-$n"
    ) >"$TEST_DIR/writer-$n.out" 2>"$TEST_DIR/writer-$n.err" || true
  done
  [ "$(cat "$work_dir/.gitignore")" = "$(printf '*.log\ninnovation_summary/')" ] ||
    fail "a writer team did not add its output directory to .gitignore exactly once"

  work_dir="$TEST_DIR/no-writer-work"
  mkdir -p "$work_dir"
  printf 'lead ./missing-agent manager\ncheck ./missing-agent reviewer\nboss ./missing-agent implementer\n' >"$config_dir/team.conf"
  git -C "$work_dir" init -q
  (
    cd "$work_dir"
    PATH="$fake_bin:$PATH" HOME="$home_dir" TMPDIR="$TEST_DIR" \
      FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=launch FAKE_TMUX_PANES=3 \
      "$ROOT/peon-code.sh" -c "$config_dir/team.conf" no-writer-test
  ) >"$TEST_DIR/no-writer.out" 2>"$TEST_DIR/no-writer.err" || true
  [ ! -e "$work_dir/.gitignore" ] || fail "a team without a writer wrote .gitignore"
}

fake_bin=$(make_fake_commands)
test_config_loading "$fake_bin"
test_shipped_roles
test_role_frontmatter "$fake_bin"
test_writer_gitignore "$fake_bin"
echo "config: PASS"
