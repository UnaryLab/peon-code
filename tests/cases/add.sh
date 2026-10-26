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
# shellcheck disable=SC2034,SC2317 # Shared launch functions call these test providers.
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
  assert_contains "$log" "-c $project -e PEON_CODE_SESSION=$session -e DISABLE_AUTO_UPDATE=true"
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

# shellcheck disable=SC2034,SC2317 # Shared launch functions call these test providers.
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
echo 'add: PASS'
