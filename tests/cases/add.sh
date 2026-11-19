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
# shellcheck source=lib/commands.sh
source "$ROOT/lib/commands.sh"
# shellcheck source=lib/brief.sh
source "$ROOT/lib/brief.sh"
# shellcheck source=lib/launch.sh
source "$ROOT/lib/launch.sh"
# shellcheck source=lib/tmux.sh
source "$ROOT/lib/tmux.sh"
die() { printf 'peon-code: %s\n' "$*" >&2; exit 1; }

# Use real panes on a private server; replace CLI startup and delivery only.
# shellcheck disable=SC2034,SC2317,SC2329 # Shared launch functions call these test providers.
test_add() (
  local socket="peon-add-test-$$" session="add-test-$$" project="$TEST_DIR/add-project" caller="$TEST_DIR/add-caller"
  local log="$TEST_DIR/add-splits" notices="$TEST_DIR/add-notices" pane brief before index i
  local BRIEF_DIR="$TEST_DIR/add-briefs" MAIN=0 N=3
  local NAMES=(boss impl archie) CMDS=('sleep 600' 'sleep 600' 'sleep 600')
  local ROLES=("$ROOT/roles/manager.md" "$ROOT/roles/implementer.md" "$ROOT/roles/reviewer.md")
  local PANE_IDS=()
  tmux() {
    [ "$1" != split-window ] || printf '%s\n' "$*" >>"$log"
    command tmux -L "$socket" -f /dev/null "$@"
  }
  trap 'tmux kill-session -t "=$session" 2>/dev/null || true' EXIT
  systemd-run() { return 1; }
  sleep_launch_command() { printf 'sleep 600\n'; }
  with_pane_delivery() { shift; "$@"; }
  launch_command_locked() { tmux send-keys -t "$1" -l "$2"; tmux send-keys -t "$1" Enter; }
  cmd_send() { printf '%s %s\n' "$1" "$2" >>"$notices"; [ "$1" != "${PANE_IDS[1]}" ]; }
  mkdir -p "$project" "$caller/roles" "$BRIEF_DIR"
  printf '%s\n' '---' 'type: worker' 'description: Local worker' '---' 'Build the task.' >"$caller/roles/local-worker.md"
  cd "$project"
  create_agent_session "$session" 3 0
  tmux set-option -t "$session" @peon_restart 0
  tmux set-option -t "$session" @peon_compact_at 0
  for i in "${!NAMES[@]}"; do
    initialize_agent_pane "$i"
    index=$i
    [ "$i" -eq 0 ] || index=$((i + 1))
    brief="$BRIEF_DIR/$index.md"
    printf 'original brief for %s\n' "${NAMES[$i]}" >"$brief"
    tmux set -pt "${PANE_IDS[$i]}" @peon_brief "$brief"
    # Uploaded role paths can be gone by the time another pane joins.
    tmux set -pt "${PANE_IDS[$i]}" @peon_role "$TEST_DIR/deleted-role-$i.md"
  done
  : >"$log"
  cd "$caller"
  PEON_CODE_SESSION=$session cmd_add helper local-worker sleep 600 >"$TEST_DIR/add.out" 2>"$TEST_DIR/add.err"
  pane=$(tmux list-panes -s -t "=$session" -F '#{pane_id} #{@peon_name}' | awk '$2 == "helper" { print $1 }')
  [ -n "$pane" ] || fail 'add did not create the named agent pane'
  [ "$(tmux show-options -pqv -t "$pane" @peon_cmd)" = 'sleep 600' ] || fail 'add lost the agent command'
  [ "$(tmux show-options -pqv -t "$pane" @peon_bin)" = sleep ] || fail 'add lost the CLI binary'
  [ "$(tmux show-options -pqv -t "$pane" @peon_role)" = "$caller/roles/local-worker.md" ] || fail 'add resolved a local role against the project instead of the caller'
  [ "$(tmux show-options -pqv -t "$pane" @peon_role_type)" = worker ] || fail 'add lost the role type'
  [ "$(tmux show-options -pqv -t "$pane" @peon_role_label)" = local-worker ] || fail 'add lost the role label'
  [ "$(tmux show-options -pqv -t "$pane" @peon_role_desc)" = 'Local worker' ] || fail 'add lost the role description'
  [ "$(tmux show-options -pqv -t "$pane" @peon_main)" = 0 ] || fail 'add changed the main agent'
  [ "$(tmux show-options -pqv -t "$pane" @peon_brief_dir)" = "$BRIEF_DIR" ] || fail 'add lost the brief directory'
  [ "$(tmux display-message -pt "$pane" '#{pane_current_path}')" = "$project" ] || fail 'new agent did not start in the session project'
  brief=$(tmux show-options -pqv -t "$pane" @peon_brief)
  [ "$brief" = "$BRIEF_DIR/pane-${pane#%}.md" ] || fail 'new brief can overwrite an existing index brief'
  assert_contains "$brief" 'one of 4 AI coding agents'
  assert_contains "$brief" "pane ${PANE_IDS[0]}: boss (sleep 600) - manager (manager):"
  assert_contains "$brief" "pane $pane: helper (sleep 600) - local-worker (worker): Local worker"
  assert_contains "$brief" 'Build the task.'
  assert_contains "$brief" "only in the boss pane (${PANE_IDS[0]})"
  assert_contains "$brief" 'Hard prohibition for this pane'
  [ -n "$(tmux show-options -pqv -t "$pane" @peon_launch)" ] || fail 'add did not store the launch command'
  for index in 0 2 3; do
    assert_contains "$BRIEF_DIR/$index.md" 'original brief for'
    assert_contains "$BRIEF_DIR/$index.md" "New teammate, add to the roster above: pane $pane: helper (sleep 600) - local-worker (worker): Local worker"
  done
  [ "$(wc -l <"$notices" | tr -d ' ')" = 3 ] || fail 'add did not notify every existing pane exactly once'
  assert_contains "$notices" "[from peon-code] New teammate: pane $pane: helper (sleep 600) - local-worker (worker): Local worker"
  assert_contains "$TEST_DIR/add.err" "could not notify impl ${PANE_IDS[1]} about helper"
  assert_contains "$log" "-c $project -e PEON_CODE_SESSION=$session -e DISABLE_AUTO_UPDATE=true -e CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1"
  before=$(wc -l <"$log")
  for name in 'bad name' boss second-manager missing-role bad-type; do
    case $name in
      second-manager) role=manager ;;
      missing-role) role=missing ;;
      bad-type)
        printf '%s\n' '---' 'type: invalid' '---' 'Task.' >"$caller/roles/bad-type.md"
        role=bad-type ;;
      *) role=implementer ;;
    esac
    if (cmd_add "$name" "$role" sleep 600 --session "$session") >"$TEST_DIR/add-invalid.out" 2>"$TEST_DIR/add-invalid.err"; then
      fail "add accepted invalid agent: $name"
    fi
    case $name in
      'bad name') assert_contains "$TEST_DIR/add-invalid.err" 'must be letters, digits, _ or -' ;;
      boss) assert_contains "$TEST_DIR/add-invalid.err" 'is used twice' ;;
      second-manager) assert_contains "$TEST_DIR/add-invalid.err" 'already has a manager' ;;
      missing-role) assert_contains "$TEST_DIR/add-invalid.err" 'role file not found' ;;
      bad-type) assert_contains "$TEST_DIR/add-invalid.err" 'needs a frontmatter type' ;;
    esac
  done
  [ "$(wc -l <"$log")" = "$before" ] || fail 'invalid add split a new pane'
  # A failed startup removes only its new pane and leaves prior briefs alone.
  if (wait_agent_ready() { return 1; }; cmd_add failed implementer sleep 600 --session "$session") >"$TEST_DIR/add-failed.out" 2>"$TEST_DIR/add-failed.err"; then
    fail 'add accepted an agent that never became ready'
  fi
  assert_contains "$TEST_DIR/add-failed.err" 'failed to start; killed new pane'
  [ "$(tmux list-panes -s -t "=$session" -F '#{pane_id}' | wc -l | tr -d ' ')" = 4 ] || fail 'failed add removed an existing pane or kept its new pane'
  assert_not_contains "$BRIEF_DIR/0.md" ': failed ('
  # Start a missing watcher, then keep a running watcher when another pane joins.
  nohup() { printf '%s\n' "$*" >>"$TEST_DIR/add-watchers"; }
  tmux set-option -t "$session" @peon_restart 1
  cmd_add watched - sleep 'two words' --session "$session" >"$TEST_DIR/add-watched.out" 2>"$TEST_DIR/add-watched.err"
  pane=$(tmux list-panes -s -t "=$session" -F '#{pane_id} #{@peon_name}' | awk '$2 == "watched" { print $1 }')
  [ "$(tmux show-options -pqv -t "$pane" @peon_cmd)" = 'sleep two\ words' ] || fail 'add split an argument that contains spaces'
  for i in 1 2 3 4 5; do
    [ ! -s "$TEST_DIR/add-watchers" ] || break
    sleep 0.05
  done
  assert_contains "$TEST_DIR/add-watchers" "$ROOT/peon-code.sh watch $session 0"
  tmux set-option -t "$session" @peon_watch_pid "$$"
  (
    ps() { printf 'bash %s/peon-code.sh watch %s 0\n' "$ROOT" "$session"; }
    cmd_add watched-again - sleep 600 --session "$session"
  ) >"$TEST_DIR/add-watched-again.out" 2>"$TEST_DIR/add-watched-again.err"
  [ "$(wc -l <"$TEST_DIR/add-watchers" | tr -d ' ')" = 1 ] || fail 'add started a second watcher'
  # Exercise CLI dispatch too; duplicate validation exits before any split.
  if TMUX="$(tmux display-message -p '#{socket_path}'),0,0" "$ROOT/peon-code.sh" add boss - sleep 600 --session "$session" >"$TEST_DIR/add-dispatch.out" 2>"$TEST_DIR/add-dispatch.err"; then
    fail 'add CLI dispatch accepted a duplicate agent'
  fi
  assert_contains "$TEST_DIR/add-dispatch.err" 'is used twice'
  # A roleless team can grow only with another roleless agent.
  while read -r pane; do
    tmux set -pt "$pane" @peon_role_type ''
  done < <(tmux list-panes -s -t "=$session" -F '#{pane_id}')
  before=$(wc -l <"$log")
  if cmd_add typed implementer 'sleep 600' --session "$session" >"$TEST_DIR/add-roleless.out" 2>"$TEST_DIR/add-roleless.err"; then
    fail 'add accepted a typed role in a roleless team'
  fi
  assert_contains "$TEST_DIR/add-roleless.err" "session $session has no roles; add a roleless agent (-) or launch a role team"
  [ "$(wc -l <"$log")" = "$before" ] || fail 'typed add split a pane in a roleless team'
  cmd_add plain - 'sleep 600' --session "$session" >"$TEST_DIR/add-plain.out" 2>"$TEST_DIR/add-plain.err"
  pane=$(tmux list-panes -s -t "=$session" -F '#{pane_id} #{@peon_name}' | awk '$2 == "plain" { print $1 }')
  [ -n "$pane" ] || fail 'add refused a roleless agent in a roleless team'
  [ -z "$(tmux show-options -pqv -t "$pane" @peon_role_type)" ] || fail 'roleless add stored a role type'
  [ "$(tmux show-options -pqv -t "$pane" @peon_cmd)" = 'sleep 600' ] || fail 'three-field add changed the command'
)
test_add

# shellcheck disable=SC2034,SC2317,SC2329 # Shared launch functions call these test providers.
test_add_save() (
  local socket="peon-add-save-$$" session="add-save-$$" project="$TEST_DIR/save-project" caller="$TEST_DIR/save-caller"
  local BRIEF_DIR="$TEST_DIR/save-briefs" MAIN=0 N=3 i pane conf user_conf
  local NAMES=(boss impl archie) CMDS=('sleep 600' 'sleep 600' 'sleep 600')
  local ROLES=("$ROOT/roles/manager.md" "$ROOT/roles/implementer.md" "$ROOT/roles/reviewer.md") PANE_IDS=()
  tmux() { command tmux -L "$socket" -f /dev/null "$@"; }
  trap 'tmux kill-session -t "=$session" 2>/dev/null || true' EXIT
  systemd-run() { return 1; }
  sleep_launch_command() { printf 'sleep 600\n'; }
  with_pane_delivery() { shift; "$@"; }
  launch_command_locked() { tmux send-keys -t "$1" -l "$2"; tmux send-keys -t "$1" Enter; }
  cmd_send() { :; }
  mkdir -p "$project/roles" "$caller" "$BRIEF_DIR"
  cp "$ROOT/roles/implementer.md" "$project/roles/kept-worker.md"
  cp "$ROOT/roles/implementer.md" "$caller/copied-worker.md"
  cp "$ROOT/roles/implementer.md" "$caller/ephemeral.md"
  cd "$project"
  create_agent_session "$session" 3 0
  tmux resize-window -t "$session":agents -x 200 -y 100
  tmux set-option -t "$session" @peon_restart 0
  tmux set-option -t "$session" @peon_compact_at 0
  for i in "${!NAMES[@]}"; do
    initialize_agent_pane "$i"
    printf 'original brief\n' >"$BRIEF_DIR/$i.md"
    tmux set -pt "${PANE_IDS[$i]}" @peon_brief "$BRIEF_DIR/$i.md"
  done
  tmux set -pt "${PANE_IDS[1]}" @peon_role_label kept-worker
  cd "$caller"
  cmd_add volatile "$caller/ephemeral.md" 'sleep 600' --session "$session" >"$TEST_DIR/save.out" 2>"$TEST_DIR/save.err"
  [ ! -e "$project/peon-code.conf" ] || fail 'add without --save created a config'
  [ ! -e "$project/roles/ephemeral.md" ] || fail 'add without --save copied a role'
  mv "$caller/ephemeral.md" "$caller/ephemeral-source.md"
  tmux set-option -t "$session" @peon_conf "$caller/deleted.conf"
  if cmd_add missing-role "$caller/copied-worker.md" 'sleep 600' --save --session "$session" >"$TEST_DIR/save.out" 2>"$TEST_DIR/save.err"; then
    fail 'save dropped an existing agent role'
  fi
  assert_contains "$TEST_DIR/save.err" 'cannot save agent volatile: missing role ephemeral; write roles/ephemeral.md next to the config first'
  [ ! -e "$project/peon-code.conf" ] || fail 'missing existing role created a config'
  [ ! -e "$project/roles/copied-worker.md" ] || fail 'missing existing role copied the new role'
  cp "$caller/ephemeral-source.md" "$project/roles/ephemeral.md"
  user_conf="$TEST_DIR/save-home/.config/peon-code/peon-code.conf"
  mkdir -p "$(dirname -- "$user_conf")"
  printf '# User config\n*global codex -\n' >"$user_conf"
  cp "$user_conf" "$TEST_DIR/save-user.expected"
  tmux set-option -t "$session" @peon_conf "$user_conf"
  HOME="$TEST_DIR/save-home" cmd_add persisted "$caller/copied-worker.md" 'sleep 600' --save --session "$session" >"$TEST_DIR/save.out" 2>"$TEST_DIR/save.err"
  cmp "$TEST_DIR/save-user.expected" "$user_conf" || fail 'save changed the user config'
  conf="$project/peon-code.conf"
  printf '%s\n' '*boss sleep 600 manager' 'impl sleep 600 kept-worker' 'archie sleep 600 reviewer' \
    'volatile sleep 600 ephemeral' 'persisted sleep 600 copied-worker' >"$TEST_DIR/save.expected"
  cmp "$TEST_DIR/save.expected" "$conf" || fail 'save did not rebuild the full roster and main marker'
  cmp "$caller/copied-worker.md" "$project/roles/copied-worker.md" || fail 'save changed the copied role'
  [ "$(tmux show-options -qv -t "$session" @peon_conf)" = "$conf" ] || fail 'save did not store the new config path'
  tmux set-option -t "$session" @peon_conf "$caller/deleted.conf"
  if cmd_add unrelated - 'sleep 600' --save --session "$session" >"$TEST_DIR/save.out" 2>"$TEST_DIR/save.err"; then
    fail 'save appended to a project config that the session did not use'
  fi
  assert_contains "$TEST_DIR/save.err" 'config already exists but was not used by this session'
  cmp "$TEST_DIR/save.expected" "$conf" || fail 'save changed an unrelated project config'
  tmux set-option -t "$session" @peon_conf "$user_conf"
  if HOME="$TEST_DIR/save-home" cmd_add unrelated-user - 'sleep 600' --save --session "$session" >"$TEST_DIR/save.out" 2>"$TEST_DIR/save.err"; then
    fail 'save appended to a user config when the project config already existed'
  fi
  cmp "$TEST_DIR/save-user.expected" "$user_conf" || fail 'save changed the user config on conflict'
  cmp "$TEST_DIR/save.expected" "$conf" || fail 'save changed a conflicting project config'
  mkdir -p "$project/saved elsewhere"
  conf="$project/saved elsewhere/team.conf"
  printf '# Preserve this comment\ncompact-at 0\n*original codex -' >"$conf"
  cp "$conf" "$TEST_DIR/save-existing.expected"
  printf '\nshipped sleep 600 implementer\n' >>"$TEST_DIR/save-existing.expected"
  tmux set-option -t "$session" @peon_conf "$conf"
  cmd_add shipped implementer 'sleep 600' --session "$session" --save >"$TEST_DIR/save.out" 2>"$TEST_DIR/save.err"
  cmp "$TEST_DIR/save-existing.expected" "$conf" || fail 'save rewrote existing config lines or lost a missing final newline'
  cmp "$TEST_DIR/save.expected" "$project/peon-code.conf" || fail 'save ignored the recorded config path'
  mkdir -p "$project/saved elsewhere/roles"
  printf 'Different role\n' >"$project/saved elsewhere/roles/copied-worker.md"
  if cmd_add clash "$caller/copied-worker.md" 'sleep 600' --save --session "$session" >"$TEST_DIR/save.out" 2>"$TEST_DIR/save.err"; then
    fail 'save overwrote a clashing role file'
  fi
  assert_contains "$TEST_DIR/save.err" 'role file already exists with different content'
  cmp "$TEST_DIR/save-existing.expected" "$conf" || fail 'role clash changed the config'
  [ "$(cat "$project/saved elsewhere/roles/copied-worker.md")" = 'Different role' ] || fail 'role clash changed the existing role'
  cp "$caller/copied-worker.md" "$caller/failed-worker.md"
  if (wait_agent_ready() { return 1; }; cmd_add failed "$caller/failed-worker.md" 'sleep 600' --save --session "$session") >"$TEST_DIR/save.out" 2>"$TEST_DIR/save.err"; then
    fail 'saved an agent that failed to start'
  fi
  cmp "$TEST_DIR/save-existing.expected" "$conf" || fail 'failed launch changed the config'
  [ ! -e "$project/saved elsewhere/roles/failed-worker.md" ] || fail 'failed launch copied its role'
  cmd_add unsaved - 'sleep 600' --session "$session" >"$TEST_DIR/save.out" 2>"$TEST_DIR/save.err"
  cmp "$TEST_DIR/save-existing.expected" "$conf" || fail 'add without --save changed an existing config'
)
test_add_save

# shellcheck disable=SC2034,SC2317,SC2329,SC2119 # Launch mocks read these globals; load_team reads a config, not CLI arguments.
test_add_team() (
  local mode=${1:-config}
  local socket="peon-add-team-$mode-$$" session="add-team-$mode-$$" project="$TEST_DIR/team project-$mode" caller="$TEST_DIR/team-caller-$mode"
  local SESSION=$session BRIEF_DIR="$TEST_DIR/team-briefs" MAIN=0 N=3 CONF="$caller/team.conf" CONF_GIVEN=1 DEFAULT_CONF=""
  # A pane named all must not turn a rebrief into a broadcast.
  local NAMES=(boss impl all) CMDS=('sleep 600' 'sleep 600' 'sleep 600')
  local ROLES=("$ROOT/roles/manager.md" "$ROOT/roles/implementer.md" "$ROOT/roles/reviewer.md") PANE_IDS=()
  local TEAM_NAMES=("$session") TEAMS=("$session" "$session" "$session") MAIN_INDEX COMPACT_AT RESTART_DEAD
  local i director pane old_main manager_pane root_conf="$project/peon-code.conf" old_order before width height expected_command='sleep 600' dead_holder
  tmux() {
    [ "$1" != split-window ] || printf '%s\n' "$*" >>"$TEST_DIR/team-splits"
    command tmux -L "$socket" -f /dev/null "$@"
  }
  trap 'tmux kill-session -t "=$session" 2>/dev/null || true' EXIT
  systemd-run() { return 1; }
  sleep_launch_command() {
    if [ "$mode" = restart-failure ] && [ "${5:-}" = 0 ]; then return 1; fi
    if [ "${5:-}" = 0 ]; then printf 'sleep 600 # restart index 0 main %s\n' "$MAIN"; return; fi
    printf 'sleep 600\n'
  }
  with_pane_delivery() { shift; "$@"; }
  launch_command_locked() { tmux send-keys -t "$1" -l "$2"; tmux send-keys -t "$1" Enter; }
  cmd_send() { :; }
  nohup() { printf '%s\n' "$*" >>"$TEST_DIR/team-watchers-$mode"; }
  rebrief_pane() {
    local restart
    restart=$(tmux show-options -pqv -t "$manager_pane" @peon_launch)
    if [ "$mode" = restart-failure ]; then
      [ -z "$restart" ] || fail 'rebrief kept the unsafe manager restart command after rebuild failure'
    else
      [ "$restart" = 'sleep 600 # restart index 0 main 6' ] || fail 'rebrief ran before the manager restart command was rebuilt'
    fi
    printf '%s %s\n' "$1" "$2" >>"$TEST_DIR/team-rebriefs"
    [ "$2" != impl ] || return 3
  }
  mkdir -p "$project" "$caller" "$BRIEF_DIR"
  : >"$TEST_DIR/team-rebriefs"
  cp "$ROOT/roles/implementer.md" "$caller/editor.md"
  printf '*boss sleep 600 manager\nimpl sleep 600 ./editor.md\ncheck sleep 600 reviewer\n' >"$CONF"
  if [ "$mode" = config ]; then
    mkdir -p "$project/config dir"
    root_conf="$project/config dir/session.conf"
    printf '# Keep this comment\n*boss sleep 600 manager\nimpl sleep 600 implementer\nall sleep 600 reviewer' >"$root_conf"
  fi
  cd "$project"
  create_agent_session "$session" 3 0
  read -r width height < <(tmux display -p -t "$session":agents '#{window_width} #{window_height}')
  [ "$width" -ge 220 ] && [ "$height" -ge 60 ] || fail "headless session window is only $width by $height"
  if [ "$mode" = config ]; then tmux set-option -t "$session" @peon_conf "$root_conf"; fi
  tmux set-option -t "$session" @peon_restart 0
  tmux set-option -t "$session" @peon_compact_at 0
  for i in "${!NAMES[@]}"; do
    initialize_agent_pane "$i"
    printf 'original brief %s\n' "$i" >"$BRIEF_DIR/$i.md"
    tmux set -pt "${PANE_IDS[$i]}" @peon_brief "$BRIEF_DIR/$i.md"
    tmux respawn-pane -k -t "${PANE_IDS[$i]}" 'exec sleep 600'
    wait_agent_ready "${PANE_IDS[$i]}"
  done
  old_main=${PANE_IDS[0]}; old_order="${PANE_IDS[*]}"
  manager_pane=$old_main
  tmux set -pt "$old_main" @peon_launch unsafe-manager-launch
  tmux set-option -t "$session" @peon_pane_order "$old_order"
  cd "$caller"
  if cmd_add_team --director 'sleep 700' --session "$session" >"$TEST_DIR/team-director.out" 2>"$TEST_DIR/team-director.err"; then fail 'add-team accepted --director'; fi
  assert_contains "$TEST_DIR/team-director.err" 'unknown add-team argument: --director'
  # Both commands must leave another operation's lock and panes alone.
  mkdir "$BRIEF_DIR/add.lock"
  printf '%s\n' "$$" >"$BRIEF_DIR/add.lock/owner"
  if cmd_add_team --team locked --session "$session" >"$TEST_DIR/team-lock.out" 2>"$TEST_DIR/team-lock.err"; then fail 'add-team ignored its session lock'; fi
  assert_contains "$TEST_DIR/team-lock.err" "another add or add-team is running in session $session; retry after it finishes"
  if cmd_add locked implementer 'sleep 600' --session "$session" >"$TEST_DIR/team-lock.out" 2>"$TEST_DIR/team-lock.err"; then fail 'add ignored the add-team lock'; fi
  assert_contains "$TEST_DIR/team-lock.err" "another add or add-team is running in session $session; retry after it finishes"
  assert_contains "$TEST_DIR/team-lock.err" "Lock: $BRIEF_DIR/add.lock; remove it only when no add or add-team is running"
  [ -d "$BRIEF_DIR/add.lock" ] || fail 'refused operation removed another operation lock'
  [ "$(cat "$BRIEF_DIR/add.lock/owner")" = "$$" ] || fail 'refused operation changed the live lock owner'
  rm "$BRIEF_DIR/add.lock/owner"
  rmdir "$BRIEF_DIR/add.lock"
  # A finished holder can be reclaimed; its replacement records the actual subshell.
  dead_holder=$(sh -c 'echo "$$"')
  kill -0 "$dead_holder" 2>/dev/null && fail 'test lock owner is still running'
  mkdir "$BRIEF_DIR/add.lock"
  printf '%s\n' "$dead_holder" >"$BRIEF_DIR/add.lock/owner"
  (
    local add_holder actual committed=1
    add_lock
    actual=$(exec sh -c 'echo "$PPID"')
    [ "$(cat "$BRIEF_DIR/add.lock/owner")" = "$actual" ] || fail 'add lock recorded the invoking shell instead of its subshell holder'
    [ "$actual" != "$$" ] || fail 'add lock holder must differ from the invoking shell'
  )
  [ ! -d "$BRIEF_DIR/add.lock" ] || fail 'reclaimed add lock was not removed by its new holder'
  tmux set-option -t "$session" @peon_conf "$caller/missing.conf"
  if CONF="" cmd_add_team --session "$session" >"$TEST_DIR/team-missing.out" 2>"$TEST_DIR/team-missing.err"; then fail 'add-team accepted a missing session config'; fi
  assert_contains "$TEST_DIR/team-missing.err" "config file not found: $caller/missing.conf"
  if [ "$mode" = config ]; then tmux set-option -t "$session" @peon_conf "$root_conf"; else tmux set-option -t "$session" @peon_conf ''; fi
  printf 'Keep this config\n' >"$project/peon-code.existing.conf"
  if cmd_add_team --team existing --save --session "$session" >"$TEST_DIR/team-existing.out" 2>"$TEST_DIR/team-existing.err"; then fail 'add-team overwrote an existing team config'; fi
  assert_contains "$TEST_DIR/team-existing.err" "team config already exists: $project/peon-code.existing.conf"
  [ "$(cat "$project/peon-code.existing.conf")" = 'Keep this config' ] || fail 'add-team changed the existing team config'
  tmux set -pt "$old_main" @peon_role_type worker
  if cmd_add_team --team no-manager --session "$session" >"$TEST_DIR/team-manager.out" 2>"$TEST_DIR/team-manager.err"; then fail 'add-team used a non-manager main for the director'; fi
  assert_contains "$TEST_DIR/team-manager.err" 'main pane boss is not a manager; launch a session with its manager as main before add-team'
  tmux set -pt "$old_main" @peon_role_type manager
  [ "$(tmux list-panes -s -t "=$session" -F '#{pane_id}' | wc -l | tr -d ' ')" = 3 ] || fail 'refused add-team created panes'
  if [ "$mode" = rebuild ]; then
    if (wait_agent_ready() { return 1; }; cmd_add_team --team failed --session "$session") >"$TEST_DIR/team-failed.out" 2>"$TEST_DIR/team-failed.err"; then fail 'failed director startup succeeded'; fi
    [ "$(tmux list-panes -s -t "=$session" -F '#{pane_id}' | wc -l | tr -d ' ')" = 3 ] || fail 'failed conversion kept new panes'
    [ "$(tmux show-options -pqv -t "$old_main" @peon_main)" = 1 ] || fail 'failed conversion changed the main pane'
    [ -z "$(tmux show-options -pqv -t "$old_main" @peon_team)" ] || fail 'failed conversion changed team options'
    [ ! -e "$project/.peon-code-task.failed.md" ] || fail 'failed conversion kept the team board'
    [ ! -e "$project/.peon-code-plan.md" ] || fail 'failed conversion kept the plan board'
    [ ! -d "$BRIEF_DIR/add.lock" ] || fail 'failed conversion kept the add lock'
  fi
  if [ "$mode" = restart-failure ]; then
    cmd_add_team --team research --save --session "$session" >"$TEST_DIR/team-restart.out" 2>"$TEST_DIR/team-restart.err"
    assert_contains "$TEST_DIR/team-restart.err" 'cannot update the manager restart command'
    assert_contains "$TEST_DIR/team-restart.err" 'automatic restart disabled for that pane'
    [ -z "$(tmux show-options -pqv -t "$old_main" @peon_launch)" ] || fail 'rebuild failure kept the unsafe manager restart command'
    [ "$(wc -l <"$TEST_DIR/team-rebriefs" | tr -d ' ')" = 3 ] || fail 'restart command failure skipped the old panes rebrief'
    assert_contains "$BRIEF_DIR/0.md" 'D<n> done, never to the user'
    [ "$(tmux list-panes -s -t "=$session" -F '#{pane_id}' | wc -l | tr -d ' ')" = 7 ] || fail 'post-commit failure removed running panes'
    [ -f "$project/.peon-code-task.research.md" ] && [ -f "$project/.peon-code-plan.md" ] || fail 'post-commit failure removed live boards'
    [ -f "$project/peon-code.research.conf" ] || fail 'manager restart warning stopped the config save'
    [ ! -d "$BRIEF_DIR/add.lock" ] || fail 'post-commit failure kept the add lock'
    return
  fi
  tmux set-option -t "$session" @peon_restart 1
  cmd_add_team --team research --save --session "$session" >"$TEST_DIR/team-add.out" 2>"$TEST_DIR/team-add.err"
  for i in 1 2 3 4 5; do
    [ ! -s "$TEST_DIR/team-watchers-$mode" ] || break
    sleep 0.05
  done
  assert_contains "$TEST_DIR/team-watchers-$mode" "$ROOT/peon-code.sh watch $session 0"
  tmux set-option -t "$session" @peon_restart 0
  read -r width height < <(tmux display -p -t "$session":agents '#{window_width} #{window_height}')
  [ "$width" -ge 220 ] && [ "$height" -ge 73 ] || fail "add-team left the seven-pane headless window at $width by $height"
  [ "$(tmux show-options -wv -t "$session":agents window-size)" = latest ] || fail 'add-team left manual sizing on'
  while read -r width height; do
    [ "$width" -ge 80 ] && [ "$height" -ge 8 ] || fail "add-team left a small pane: $width by $height"
  done < <(tmux list-panes -t "$session":agents -F '#{pane_width} #{pane_height}')
  director=$(tmux list-panes -s -t "=$session" -F '#{pane_id} #{@peon_name}' | awk '$2 == "director" { print $1 }')
  [ -n "$director" ] || fail 'second team did not create a director'
  [ "$(tmux list-panes -t "$session":agents -F '#{pane_id}' | head -1)" = "$director" ] || fail 'director did not take position 0'
  [ "$(tmux show-options -pqv -t "$old_main" @peon_main)" = 0 ] || fail 'old main kept its main flag'
  [ -n "$(tmux show-options -pqv -t "$old_main" @peon_launch)" ] || fail 'old main has no updated restart command'
  [ "$(tmux show-options -pqv -t "$director" @peon_main)" = 1 ] || fail 'director is not main'
  [ "$(tmux show-options -pqv -t "$director" @peon_cmd)" = "$expected_command" ] || fail 'director command was lost'
  [ "$(tmux show-options -qv -t "$session" @peon_pane_order)" = "$director $old_order" ] || fail 'saved pane order lost the director'
  assert_contains "$TEST_DIR/team-add.out" 'manager boss keeps git until it is swapped or restarted'
  assert_contains "$TEST_DIR/team-add.err" 'no brief sent to impl'
  assert_contains "$TEST_DIR/team-add.err" "run peon-code.sh rebrief impl $session when it is free"
  [ "$(wc -l <"$TEST_DIR/team-rebriefs" | tr -d ' ')" = 3 ] || fail 'add-team did not rebrief only the old panes'
  while read -r pane; do
    case " $old_order " in *" $pane "*) continue ;; esac
    assert_not_contains "$TEST_DIR/team-rebriefs" "$pane "
  done < <(tmux list-panes -s -t "=$session" -F '#{pane_id}')
  for i in 0 1 2; do
    [ "$(tmux show-options -pqv -t "${PANE_IDS[$i]}" @peon_team)" = "$session" ] || fail 'existing pane has no team'
    assert_contains "$BRIEF_DIR/$i.md" "original brief $i"
    assert_contains "$BRIEF_DIR/$i.md" "This replaces rules 1 and 2 above: a director now runs intake and git in pane $director (director)."
    assert_contains "$BRIEF_DIR/$i.md" "Your team is $session: the roster lines above without a [team] tag."
    assert_contains "$BRIEF_DIR/$i.md" 'Message only your own team and the director.'
    assert_contains "$BRIEF_DIR/$i.md" 'Where rules 3, 4, and 5 say tell the user, tell the director instead.'
    assert_contains "$BRIEF_DIR/$i.md" 'D<n> done, never to the user'
    assert_contains "$BRIEF_DIR/$i.md" 'the director posts the final summary.'
    assert_contains "$BRIEF_DIR/$i.md" 'The session now has a director: never run git commit, git stash, or any history-rewriting git command; request commits from the director by message.'
    assert_contains "$BRIEF_DIR/$i.md" "The commit pane is now $director."
    assert_contains "$BRIEF_DIR/$i.md" ' [team research]'
  done
  assert_contains "$project/.peon-code-task.research.md" 'Every task cell starts with the plan row id it serves, like D2: rename parser.'
  [ "$(cat "$project/.peon-code-plan.md")" = "$PLAN_HEADER" ] || fail 'add-team did not seed the plan header'
  if [ "$mode" = config ]; then assert_contains "$root_conf" '# Keep this comment'; fi
  if [ "$mode" = config ]; then
    assert_contains "$root_conf" 'team research ../peon-code.research.conf'
  else assert_contains "$root_conf" 'team research peon-code.research.conf'; fi
  assert_not_contains "$root_conf" "director "
  printf 'boss sleep 600 manager\nimpl sleep 600 editor\ncheck sleep 600 reviewer\n' >"$TEST_DIR/team-save.expected"
  cmp "$TEST_DIR/team-save.expected" "$project/peon-code.research.conf" || fail 'saved team config has prefixes or wrong roles'
  cmp "$caller/editor.md" "$project/roles/editor.md" || fail 'custom role was not copied'
  pane=$(tmux list-panes -s -t "=$session" -F '#{pane_id} #{@peon_name}' | awk '$2 == "research-impl" { print $1 }')
  assert_contains "$(tmux show-options -pqv -t "$pane" @peon_brief)" "only in the director pane ($director)"
  assert_contains "$(tmux show-options -pqv -t "$pane" @peon_brief)" " [team $session]"
  TMUX_PANE=$pane cmd_add helper implementer 'sleep 600' --save --session "$session" >"$TEST_DIR/team-helper.out"
  read -r width height < <(tmux display -p -t "$session":agents '#{window_width} #{window_height}')
  [ "$width" -ge 220 ] && [ "$height" -ge 85 ] || fail "add left the eight-pane headless window at $width by $height"
  [ "$(tmux show-options -wv -t "$session":agents window-size)" = latest ] || fail 'add left manual sizing on'
  assert_contains "$project/peon-code.research.conf" 'helper sleep 600 implementer'
  assert_not_contains "$project/peon-code.research.conf" 'research-helper'
  [ "$(tmux show-options -qv -t "$session" @peon_conf)" = "$root_conf" ] || fail 'add changed the root config path to the team file'
  cmd_add local implementer 'sleep 600' --session "$session" >"$TEST_DIR/team-local.out"
  cmd_add explicit implementer 'sleep 600' --team research --session "$session" >"$TEST_DIR/team-explicit.out"
  before=$(tmux list-panes -s -t "=$session" -F '#{pane_id}' | wc -l)
  for i in reserved director-role second-manager unknown-team; do
    case $i in
      reserved) set -- director implementer 'sleep 600' ;;
      director-role) set -- extra director 'sleep 600' ;;
      second-manager) set -- second manager 'sleep 600' --team research ;;
      unknown-team) set -- extra implementer 'sleep 600' --team absent ;;
    esac
    if cmd_add "$@" --session "$session" >"$TEST_DIR/team-invalid.out" 2>"$TEST_DIR/team-invalid.err"; then fail "add accepted $i"; fi
  done
  if cmd_add_team --team director --session "$session" >"$TEST_DIR/team-invalid.out" 2>"$TEST_DIR/team-invalid.err"; then fail 'add-team accepted the reserved director name'; fi
  if (wait_agent_ready() { return 1; }; cmd_add_team --team failed --session "$session") >"$TEST_DIR/team-failed.out" 2>"$TEST_DIR/team-failed.err"; then fail 'failed team startup succeeded'; fi
  [ "$(tmux list-panes -s -t "=$session" -F '#{pane_id}' | wc -l)" = "$before" ] || fail 'failed team startup kept new panes or removed prior panes'
  assert_not_contains "$BRIEF_DIR/0.md" 'failed-boss'
  [ ! -e "$project/.peon-code-task.failed.md" ] || fail 'failed launch kept the team board'
  [ "$(cat "$project/.peon-code-plan.md")" = "$PLAN_HEADER" ] || fail 'failed launch changed the existing plan board'
  [ ! -d "$BRIEF_DIR/add.lock" ] || fail 'failed launch kept the add lock'
  CONF="" cmd_add_team --session "$session" >"$TEST_DIR/team-third.out" 2>"$TEST_DIR/team-third.err"
  [ "$(tmux list-panes -s -t "=$session" -F '#{@peon_name}' | grep -cx director)" = 1 ] || fail 'third team or plain add created another director'
  assert_contains "$TEST_DIR/team-third.out" "added team team2 to session $session"
  assert_contains "$project/.peon-code-task.team2.md" '| id | who | task | files | status |'
  [ "$(tmux list-panes -s -t "=$session" -F '#{@peon_name}' | grep -c '^team2-')" -eq 3 ] || fail 'session config fallback did not read only direct agent lines'
  pane=$(tmux list-panes -s -t "=$session" -F '#{pane_id} #{@peon_name}' | awk '$2 == "research-boss" { print $1 }')
  tmux kill-pane -t "$pane"
  cmd_add replacement manager 'sleep 600' --team research --session "$session" >"$TEST_DIR/team-replacement.out"
  assert_contains "$TEST_DIR/team-replacement.out" 'added research-replacement'
  if [ "$mode" = rebuild ]; then
    mv "$root_conf" "$root_conf.kept"
    mv "$project/peon-code.research.conf" "$project/peon-code.research.conf.kept"
    tmux set-option -t "$session" @peon_conf ''
    cmd_add_team --team later --save --session "$session" >"$TEST_DIR/team-later.out" 2>"$TEST_DIR/team-later.err"
    assert_contains "$root_conf" 'team research peon-code.research.conf'
    assert_contains "$root_conf" 'team team2 peon-code.team2.conf'
    assert_contains "$root_conf" 'team later peon-code.later.conf'
    assert_not_contains "$root_conf" 'research-'
    assert_contains "$project/peon-code.research.conf" 'replacement sleep 600 manager'
    before=$(tmux list-panes -s -t "=$session" -F '#{pane_id}' | wc -l | tr -d ' ')
    # shellcheck disable=SC2030 # Reload only in the child, preserving the source config for dispatch below.
    (CONF=$root_conf; load_team; [ "${#NAMES[@]}" = "$before" ]) || fail 'rebuild lost an existing team or agent'
  fi
  # Exercise dispatch without starting real CLIs: reserved team fails before splitting.
  # shellcheck disable=SC2031 # The child's config reload leaves this source config unchanged.
  if TMUX="$(tmux display-message -p '#{socket_path}'),0,0" "$ROOT/peon-code.sh" -c "$CONF" add-team --team director --session "$session" >"$TEST_DIR/team-dispatch.out" 2>"$TEST_DIR/team-dispatch.err"; then fail 'add-team dispatch accepted director as a team name'; fi
  assert_contains "$TEST_DIR/team-dispatch.err" 'team name director is reserved'
)
test_add_team
test_add_team rebuild
test_add_team restart-failure
echo 'add: PASS'
