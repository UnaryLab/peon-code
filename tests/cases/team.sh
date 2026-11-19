#!/usr/bin/env bash
set -euo pipefail
CASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/helpers.sh
. "$CASE_DIR/../helpers.sh"
SCRIPT_DIR=$ROOT
TASK_BOARD=.peon-code-task.md
# shellcheck source=lib/config.sh
source "$ROOT/lib/config.sh"
# shellcheck source=lib/session.sh
source "$ROOT/lib/session.sh"
# shellcheck source=lib/brief.sh
source "$ROOT/lib/brief.sh"
# shellcheck source=lib/launch.sh
source "$ROOT/lib/launch.sh"
die() { printf 'peon-code: %s\n' "$*" >&2; exit 1; }

# shellcheck disable=SC2034,SC2317,SC2329,SC2119 # Launch mocks use globals; load_team deliberately reads files, not CLI arguments.
test_teams() (
  local socket="peon-team-test-$$" SESSION="team-test-$$" project="$TEST_DIR/teams"
  local CONF="$project/root.conf" CONF_GIVEN=1 DEFAULT_CONF="" RESUME=0 WRITER_DIR=innovation_summary
  local SCRIPT_DIR="$project/runtime" NAMES=() CMDS=() ROLES=() TEAMS=() TEAM_NAMES=() MAIN_INDEX
  local COMPACT_AT RESTART_DEAD N MAIN PANE_IDS=() BRIEF_DIR ROSTER GIT_DENY_PROSE
  local i pane board expected width height report_to base_conf="$project/base.conf" nested_conf="$project/nested/team.conf"
  tmux() { command tmux -L "$socket" -f /dev/null "$@"; }
  trap 'tmux kill-session -t "=$SESSION" 2>/dev/null || true' EXIT
  mkdir -p "$project/runtime/roles" "$project/nested/roles"
  cp "$ROOT/roles/manager.md" "$ROOT/roles/implementer.md" "$ROOT/roles/reviewer.md" "$project/runtime/roles/"
  cp "$ROOT/roles/protocol.md" "$project/runtime/roles/"
  printf '%s\n' '---' 'type: director' 'description: Direct teams' '---' 'Direct the work.' >"$project/runtime/roles/director.md"
  printf '\n## Director duties\nDirect teams.\n' >>"$project/runtime/roles/protocol.md"
  cp "$ROOT/roles/implementer.md" "$project/nested/roles/local.md"
  printf '*boss sleep 600 manager\nimpl sleep 600 implementer\ncheck sleep 600 reviewer\n' >"$base_conf"
  printf 'compact-at ignored\nrestart-dead ignored\n*boss sleep 600 manager\n*impl sleep 600 ./roles/local.md\ncheck sleep 600 reviewer\n' >"$nested_conf"
  printf 'team deeper missing.conf\n' >>"$nested_conf"
  cp "$base_conf" "$CONF"
  printf 'compact-at 0\nrestart-dead no\n' >>"$CONF"
  load_team
  [ "${#NAMES[@]}" -eq 3 ] || fail 'one team created a director'
  [ "$MAIN_INDEX" -eq 0 ] || fail 'one team lost its main marker'
  [ "${TEAMS[*]}" = "$SESSION $SESSION $SESSION" ] || fail 'first team lost its session name'
  printf 'team research nested/team.conf\n' >>"$CONF"
  load_team 2>"$project/nested.err"
  assert_contains "$project/nested.err" "peon-code: $nested_conf line 6: team line ignored when reading one team"
  assert_contains "$project/nested.err" "peon-code: $nested_conf line 1: compact-at line ignored when reading one team"
  assert_contains "$project/nested.err" "peon-code: $nested_conf line 2: restart-dead line ignored when reading one team"
  [ "${#NAMES[@]}" -eq 7 ] || fail 'multiple teams did not append a director'
  [ "${NAMES[*]}" = 'boss impl check research-boss research-impl research-check director' ] || fail 'team names were not prefixed'
  [ "${TEAMS[*]}" = "$SESSION $SESSION $SESSION research research research " ] || fail 'team membership differs from names'
  [ "$MAIN_INDEX" -eq 6 ] || fail 'director is not main'
  [ "${CMDS[6]}" = 'sleep 600' ] || fail 'director did not copy its manager command'
  [ "${ROLES[4]}" = "$project/nested/./roles/local.md" ] || fail 'nested role path used the root config directory'
  [ "$COMPACT_AT:$RESTART_DEAD" = 0:no ] || fail 'nested watcher options changed root options'
  # The director uses the first team's manager command.
  { cat "$base_conf"; printf 'compact-at 0\nrestart-dead no\nteam research nested/team.conf\n'; } >"$CONF"
  load_team
  [ "${CMDS[6]}" = "${CMDS[0]}" ] || fail 'director did not inherit the first manager command'
  [ "$(board_for 0)" = .peon-code-task.md ] || fail 'first team board changed'
  [ "$(board_for 3)" = .peon-code-task.research.md ] || fail 'nested team board is wrong'
  [ "$(board_for 6)" = .peon-code-plan.md ] || fail 'director board is wrong'
  for expected in reserved duplicate invalid incomplete-root incomplete-nested director-root director-nested director-config director-name-nested missing-team session-name no-manager prefix-collision; do
    cp "$base_conf" "$CONF"
    case $expected in
      reserved) printf '*director sleep 600 -\n' >"$CONF" ;;
      duplicate) printf 'team research nested/team.conf\nteam research nested/team.conf\n' >>"$CONF" ;;
      invalid) printf 'team bad.name nested/team.conf\n' >>"$CONF" ;;
      incomplete-root) printf 'boss sleep 600 manager\nteam research nested/team.conf\n' >"$CONF" ;;
      incomplete-nested)
        printf 'boss sleep 600 manager\n' >"$project/nested/bad.conf"
        printf 'team research nested/bad.conf\n' >>"$CONF" ;;
      director-root) printf 'lead sleep 600 director\n' >"$CONF" ;;
      director-nested)
        printf 'lead sleep 600 director\n' >"$project/nested/director.conf"
        printf 'team research nested/director.conf\n' >>"$CONF" ;;
      director-config) printf 'director sleep 700\n' >>"$CONF" ;;
      director-name-nested)
        { cat "$base_conf"; printf 'director sleep 700\n'; } >"$project/nested/director-name.conf"
        printf 'team research nested/director-name.conf\n' >>"$CONF" ;;
      session-name) printf 'team %s nested/team.conf\n' "$SESSION" >>"$CONF" ;;
      no-manager) printf 'impl sleep 600 implementer\ncheck sleep 600 reviewer\nteam research nested/team.conf\n' >"$CONF" ;;
      prefix-collision) printf 'research-boss sleep 600 -\nteam research nested/team.conf\n' >>"$CONF" ;;
      missing-team) printf 'team research nested/missing.conf\n' >>"$CONF" ;;
    esac
    if (load_team) >"$project/invalid.out" 2>"$project/invalid.err"; then fail "accepted $expected config"; fi
    case $expected in
      reserved) assert_contains "$project/invalid.err" 'name director is reserved' ;;
      duplicate) assert_contains "$project/invalid.err" 'team name "research" is used twice' ;;
      invalid) assert_contains "$project/invalid.err" 'must be letters, digits, _ or -' ;;
      incomplete-root) assert_contains "$project/invalid.err" "$CONF: a team with roles needs a worker-type role" ;;
      incomplete-nested) assert_contains "$project/invalid.err" "$project/nested/bad.conf: a team with roles needs a worker-type role" ;;
      director-root|director-nested) assert_contains "$project/invalid.err" 'line 1: type director is reserved for the launcher; a team names a manager, workers, and a reviewer' ;;
      director-config) assert_contains "$project/invalid.err" "$CONF line 4: name director is reserved" ;;
      director-name-nested) assert_contains "$project/invalid.err" "$project/nested/director-name.conf line 4: name director is reserved" ;;
      session-name) assert_contains "$project/invalid.err" "$CONF line 4: team name $SESSION is the session name, which the agents of this file use" ;;
      no-manager) assert_contains "$project/invalid.err" "$CONF: a team with roles needs a manager-type role among this file's own agents" ;;
      prefix-collision) assert_contains "$project/invalid.err" "$nested_conf line 3: name boss becomes research-boss after the team prefix and is used twice" ;;
      missing-team) assert_contains "$project/invalid.err" "$CONF line 4: team research: config file not found: $project/nested/missing.conf" ;;
    esac
  done
  { cat "$base_conf"; printf 'compact-at 0\nrestart-dead no\nteam research nested/team.conf\n'; } >"$CONF"
  load_team
  printf 'impl sleep 500 implementer\nboss sleep 600 manager\ncheck sleep 700 reviewer\nteam research nested/team.conf\n' >"$CONF"
  load_team
  [ "${CMDS[6]}" = 'sleep 600' ] || fail 'director copied the first worker instead of the manager'
  printf 'tool sleep 800 -\nteam research nested/team.conf\n' >"$CONF"
  load_team
  [ "${CMDS[4]}" = 'sleep 800' ] || fail 'roleless first team did not supply the director command'
  { cat "$base_conf"; printf 'compact-at 0\nrestart-dead no\nteam research nested/team.conf\n'; } >"$CONF"
  load_team
  N=${#NAMES[@]}
  cd "$project"
  wait_shell_ready() { :; }
  # Test real session construction and briefs without starting external CLIs.
  with_pane_delivery() { shift; "$@"; }
  launch_command_locked() { tmux send-keys -t "$1" -l "$2"; tmux send-keys -t "$1" Enter; }
  launch_agents() {
    local i
    for i in "${!NAMES[@]}"; do
      build_brief "$i" >"$BRIEF_DIR/$i.md"
      with_pane_delivery "${PANE_IDS[$i]}" launch_command_locked "${PANE_IDS[$i]}" 'true'
    done
  }
  goto_session() { :; }
  prepare_launch_settings() { GIT_DENY_PROSE='commit, push'; }
  launch_team </dev/null >"$project/launch.out"
  read -r width height < <(tmux display -p -t "$SESSION":agents '#{window_width} #{window_height}')
  [ "$width" -ge 220 ] && [ "$height" -ge 73 ] || fail "seven-pane headless launch window is only $width by $height"
  [ "$MAIN" -eq 6 ] || fail 'launch did not use director main index'
  [ "$(tmux list-panes -t "$SESSION":agents -F '#{pane_id}' | head -1)" = "${PANE_IDS[6]}" ] || fail 'director did not take the main slot'
  for i in "${!NAMES[@]}"; do
    pane=${PANE_IDS[$i]}
    [ "$(tmux show-options -pqv -t "$pane" @peon_team)" = "${TEAMS[$i]}" ] || fail 'pane lost team option'
    board=$(board_for "$i")
    if [ "${NAMES[$i]}" = director ]; then
      [ "$(cat "$board")" = "$PLAN_HEADER" ] || fail 'director board did not use D ids'
      assert_contains "$BRIEF_DIR/$i.md" 'id is D1, D2, ...'
      assert_not_contains "$BRIEF_DIR/$i.md" 'id is T1, T2, ...'
      assert_contains "$board" 'Only the director edits this file; the manager named in who reports its row by message.'
      assert_contains "$BRIEF_DIR/$i.md" 'Only the director edits this file; the manager named in who reports its row by message.'
      assert_not_contains "$board" 'Every task cell starts with the plan row id it serves'
      assert_contains "$BRIEF_DIR/$i.md" 'Stage only the files listed in the plan rows you have checked.'
      assert_not_contains "$BRIEF_DIR/$i.md" 'Stage only the files you claimed.'
    else
      assert_contains "$board" 'id is T1, T2, ...'
      assert_contains "$board" 'Every task cell starts with the plan row id it serves, like D2: rename parser.'
      assert_contains "$BRIEF_DIR/$i.md" 'Every task cell starts with the plan row id it serves, like D2: rename parser.'
      assert_contains "$BRIEF_DIR/$i.md" 'id is T1, T2, ...'
      assert_not_contains "$BRIEF_DIR/$i.md" 'id is D1, D2, ...'
      assert_contains "$BRIEF_DIR/$i.md" "You are in team ${TEAMS[$i]}. Message only panes of your own team and the director"
      assert_not_contains "$BRIEF_DIR/$i.md" 'tell the user'
      report_to='your team manager'
      [ "$(role_field "${ROLES[$i]}" type)" != manager ] || report_to='the director'
      assert_contains "$BRIEF_DIR/$i.md" "do not resend; tell $report_to."
      assert_contains "$BRIEF_DIR/$i.md" "In every case tell $report_to."
      assert_contains "$BRIEF_DIR/$i.md" "proceed on your best judgment or tell $report_to."
    fi
    case $(role_field "${ROLES[$i]}" type) in
      manager|director) assert_not_contains "$BRIEF_DIR/$i.md" 'Claim every open task assigned to you' ;;
      *) assert_contains "$BRIEF_DIR/$i.md" 'Claim every open task assigned to you' ;;
    esac
    assert_contains "$BRIEF_DIR/$i.md" "The task board is $board in the working directory."
    assert_contains "$BRIEF_DIR/$i.md" "1. Task intake: the user assigns work by typing into the director pane (${PANE_IDS[6]})."
    assert_contains "$BRIEF_DIR/$i.md" 'That agent splits the work onto the plan board and dispatches each part to a team manager, who splits it onto your team board and assigns it. The director posts the final summary to the user.'
    assert_contains "$BRIEF_DIR/$i.md" "only in the director pane (${PANE_IDS[6]})"
  done
  assert_contains "$BRIEF_DIR/0.md" "pane ${PANE_IDS[3]}: research-boss (sleep 600) - manager (manager):"
  assert_contains "$BRIEF_DIR/0.md" '[team research]'
  assert_contains "$BRIEF_DIR/0.md" "Message only panes of your own team and the director"
  assert_contains "$BRIEF_DIR/6.md" '## Director duties'
  assert_not_contains "$BRIEF_DIR/6.md" '## Worker duties'
  assert_not_contains "$BRIEF_DIR/6.md" '## Manager duties'
  assert_not_contains "$BRIEF_DIR/6.md" 'Message only panes of your own team'
  assert_contains "$BRIEF_DIR/6.md" 'In every case tell the user.'
  awk '/^To read another agent/ { exit blanks > 1 } /^$/ { blanks++; next } { blanks = 0 }' "$BRIEF_DIR/6.md" || fail 'director brief has a double blank line before the read command'
  assert_not_contains <(printf '%s' "$ROSTER" | tail -1) '[team '
  assert_contains <(printf '%s' "$ROSTER" | head -1) " [team $SESSION]"
  # Single-team panes keep their old border label.
  TEAM_NAMES=("$SESSION")
  initialize_agent_pane 0
  [ -z "$(tmux show-options -pqv -t "${PANE_IDS[0]}" @peon_team)" ] || fail 'one team changed pane borders'
)
test_teams

# shellcheck disable=SC2317,SC2329 # The sizing helper calls this tmux mock.
test_attached_window_size() (
  tmux() {
    [ "$1" = list-clients ] || fail "attached window was changed: $*"
    printf 'attached-client\n'
  }
  resize_headless_agents attached-session 20
)
test_attached_window_size

# shellcheck disable=SC2034,SC2317,SC2329 # Pane initialization reads these globals and calls this tmux mock.
test_pane_metadata_order() (
  local NAMES=(boss) CMDS=(sleep) ROLES=('') TEAMS=(solo) TEAM_NAMES=(solo)
  local PANE_IDS=(%1) MAIN=0 BRIEF_DIR="$TEST_DIR/metadata" log="$TEST_DIR/metadata.log"
  tmux() { printf '%s\n' "$*" >>"$log"; }
  initialize_agent_pane 0
  [ "$(tail -n 1 "$log")" = 'set -pt %1 @peon_name boss' ] || fail 'pane name became visible before its metadata'
  assert_contains "$log" 'set -pt %1 @peon_team'
  assert_contains "$log" 'set -pt %1 @peon_role_type'
)
test_pane_metadata_order
echo 'team: PASS'
