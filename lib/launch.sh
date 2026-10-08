# shellcheck shell=bash

launch_command_locked() {
  local pane=$1 command=$2
  printf '%s' "$command" | paste_only "$pane" || return 1
  sleep 1
  tmux send-keys -t "$pane" Enter
}

# The brief marker that identifies each agent's own thread, so two panes of
# the same CLI in one directory do not both reopen the newest conversation.
# The trailing comma closes the session name, so a session name that is a
# prefix of another never matches the other's transcripts.
RESUME_IDS=()
for i in "${!NAMES[@]}"; do
  RESUME_IDS+=("")
  [ "$RESUME" -eq 1 ] || continue
  RESUME_IDS[i]=$(last_thread_id "agent ${NAMES[$i]} of peon-code session $SESSION," "${CMDS[$i]%% *}")
  [ -n "${RESUME_IDS[$i]}" ] ||
    echo "peon-code: no earlier thread for ${NAMES[$i]}; starting it fresh" >&2
done

# Only a team with roles gets a board seeded; a throwaway CLI team would
# leave an untracked file behind in a directory that never coordinates.
HAS_ROLES=0
for role_path in ${ROLES[@]+"${ROLES[@]}"}; do
  [ -n "$role_path" ] && HAS_ROLES=1
done
if [ "$HAS_ROLES" -eq 1 ] && [ ! -f "$TASK_BOARD" ]; then
  printf '%s\n' "$BOARD_HEADER" >"$TASK_BOARD"
fi

# The writer's output directory stays out of version control: a team with a
# writer gets it listed in .gitignore once, when the directory is a git repo.
for i in "${!ROLES[@]}"; do
  if [ "$(role_label "${ROLES[$i]}")" = writer ] &&
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 &&
    ! { [ -f .gitignore ] && grep -qx "$WRITER_DIR/" .gitignore; }; then
    # A .gitignore with no trailing newline would swallow the new line.
    [ ! -s .gitignore ] || [ -z "$(tail -c1 .gitignore)" ] || printf '\n' >>.gitignore
    printf '%s/\n' "$WRITER_DIR" >>.gitignore
    break
  fi
done

# The pane the user types into gets the main slot: the agent marked * in the
# config, else the first manager-type role, else pane 0. Brief rule 1 names
# this pane as the task-intake pane.
MAIN=$MAIN_INDEX
if [ "$MAIN" -lt 0 ]; then
  MAIN=0
  for i in "${!ROLES[@]}"; do
    if [ "$(role_field "${ROLES[$i]}" type)" = manager ]; then
      MAIN=$i
      break
    fi
  done
fi

create_agent_session "$SESSION" "$N" "$MAIN"
FAILED_AGENTS=()
for i in "${!NAMES[@]}"; do
  tmux set -pt "${PANE_IDS[$i]}" @peon_name "${NAMES[$i]}"
  tmux set -pt "${PANE_IDS[$i]}" @peon_role_type "$(role_field "${ROLES[$i]}" type)"
  # The CLI binary, read by the watcher to pick the transcript parser.
  tmux set -pt "${PANE_IDS[$i]}" @peon_bin "${CMDS[$i]%% *}"
  wait_shell_ready "${PANE_IDS[$i]}"
done

# Briefs go to files: pasting one on a shell command line would fill the
# pane with thousands of escaped characters before the agent even starts.
# The directory is left for the OS to clear, since the launcher
# ends in exec and the panes read the files after it is gone.
BRIEF_DIR=$(mktemp -d "${TMPDIR:-/tmp}/peon-code.XXXXXX")

# The destructive git commands denied to every agent that is not main. This
# list is the one source: the deny file below and the brief prohibition
# sentence are both built from it.
# The deny rules match a literal command prefix, so they do not block git
# invoked through a global flag (git -C dir reset, git --work-tree=... clean).
# Closing that needs a permission hook, not a deny list.
GIT_DENY=(
  "git reset" "git checkout" "git restore" "git switch" "git clean"
  "git stash" "git rm" "git commit" "git branch -D" "git branch -M"
  "git branch --delete" "git branch -f" "git push" "git rebase"
  "git reflog expire" "git update-ref" "git filter-branch" "git gc"
)

# Claude uses the normal screen, with git denied outside the main pane.
# The deny rules bind the pane and every subagent it spawns, which role prose does not.
NORMAL_TUI=default
STATUSLINE_SETTINGS=""
if command -v python3 >/dev/null 2>&1; then
  # Only the user's global settings are read; merge other scopes if needed.
  STATUSLINE_SETTINGS=$(python3 -c '
import json
import shlex
import sys

command = shlex.quote(sys.argv[2]) + " statusline"
try:
    with open(sys.argv[1], encoding="utf-8") as file:
        user_command = json.load(file).get("statusLine", {}).get("command", "")
    if isinstance(user_command, str) and user_command:
        command += " " + shlex.quote(user_command)
except (OSError, ValueError, AttributeError):
    pass
print(", \"statusLine\": " + json.dumps({"type": "command", "command": command}), end="")
' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" "$SCRIPT_DIR/peon-code.sh" 2>/dev/null
  ) || STATUSLINE_SETTINGS=""
fi
NORMAL_SETTINGS="$BRIEF_DIR/normal-screen.json"
printf '{"tui":"%s"%s}\n' "$NORMAL_TUI" "$STATUSLINE_SETTINGS" >"$NORMAL_SETTINGS"
DENY_SETTINGS="$BRIEF_DIR/deny-git.json"
{
  printf '{\n  "tui": "%s"%s,\n  "permissions": {\n    "deny": [\n' "$NORMAL_TUI" "$STATUSLINE_SETTINGS"
  DENY_SEP=""
  for CMD in "${GIT_DENY[@]}"; do
    printf '%s      "Bash(%s)", "Bash(%s:*)"' "$DENY_SEP" "$CMD" "$CMD"
    DENY_SEP=$',\n'
  done
  printf '\n    ]\n  }\n}\n'
} >"$DENY_SETTINGS"

# The same list as prose, for the brief sentence: git plus the bare forms.
GIT_DENY_PROSE=""
for CMD in "${GIT_DENY[@]}"; do
  GIT_DENY_PROSE="${GIT_DENY_PROSE:+$GIT_DENY_PROSE, }${CMD#git }"
done

# Roster line for every pane, shared by all briefs.
ROSTER=""
for i in "${!NAMES[@]}"; do
  ROSTER+="pane ${PANE_IDS[$i]}: ${NAMES[$i]} (${CMDS[$i]}) - $(role_label "${ROLES[$i]}")"
  if [ -n "${ROLES[$i]}" ]; then
    ROSTER+=" ($(role_field "${ROLES[$i]}" type)): $(role_field "${ROLES[$i]}" description)"
  fi
  ROSTER+=$'\n'
done

# Send every agent's launch command first, then wait for each CLI and paste
# a claude pane's brief once it settles. Agents that never started are named
# in FAILED_AGENTS.
launch_agents() {
  local command bin physical_dir
  local project_dirs=()
  physical_dir=$(pwd -P)
  project_dirs=("$physical_dir")
  [ "$physical_dir" = "$PWD" ] || project_dirs+=("$PWD")
  for bin in "${CLI_PROVIDERS[@]}"; do
    for command in "${CMDS[@]}"; do
      [ "${command%% *}" = "$bin" ] || continue
      cli_call "$bin" trust_project "${project_dirs[@]}"
      break
    done
  done
  for i in "${!NAMES[@]}"; do
    BRIEF=$(build_brief "$i")
    BRIEF_FILE="$BRIEF_DIR/$i.md"  # by index: a CLI-team name is the command, which can hold / or repeat
    printf '%s' "$BRIEF" >"$BRIEF_FILE"
    # rebrief finds the brief through this pane option.
    tmux set -pt "${PANE_IDS[$i]}" @peon_brief "$BRIEF_FILE" ||
      echo "peon-code: tmux refused the brief path for ${NAMES[$i]} ${PANE_IDS[$i]}; rebrief will not find it" >&2
    # The pane reads the brief from the file, so the command line stays one line.
    Q="\"\$(cat $(printf %q "$BRIEF_FILE"))\""
    # Map known CLIs to their interactive-session-with-initial-prompt syntax.
    # First token is the binary; trailing user args are preserved before the flag.
    # A resume id, when there is one, goes right after the binary, since codex
    # takes it as a subcommand and every CLI reads its options after it. For
    # copilot, gemini, and qwen the id rides alongside -i: their flag
    # validation permits the pair, though their docs do not show it.
    BIN=${CMDS[$i]%% *}
    ARGS=""
    [ "${CMDS[$i]}" = "$BIN" ] || ARGS=" ${CMDS[$i]#* }"
    RID=${RESUME_IDS[$i]}
    # Quoted for the pane's shell: a qwen id can be a saved-chat tag, not a uuid.
    RID=${RID:+$(printf %q "$RID")}
    LAUNCH=$(cli_call "$BIN" launch_command "$BIN" "$ARGS" "$RID" "$Q" "$i")
    # The pane is still at its shell, whose prompt peon-code cannot predict, so
    # the box holds no text to check against: Enter follows the paste directly.
    with_pane_delivery "${PANE_IDS[$i]}" launch_command_locked "${PANE_IDS[$i]}" "$LAUNCH" ||
      echo "peon-code: no command sent to ${NAMES[$i]} ${PANE_IDS[$i]}" >&2
  done
  for i in "${!NAMES[@]}"; do
    RID=${RESUME_IDS[$i]}
    BRIEF=$(cat "$BRIEF_DIR/$i.md")
    if ! wait_agent_ready "${PANE_IDS[$i]}"; then
      FAILED_AGENTS+=("${NAMES[$i]}")
      continue
    fi
    cli_call "${CMDS[$i]%% *}" brief_after_start
  done
}

if [ -t 0 ]; then
  # The session goes on screen first and the agents start while it is up, so
  # a pane opening on a dialog is in front of you to answer. Launch notes go
  # to the status line, and a pane whose agent never started stays up. The
  # redirections keep the terminal to the tmux client alone.
  {
    launch_agents
    [ ${#FAILED_AGENTS[@]} -eq 0 ] ||
      echo "peon-code: agents failed to start: ${FAILED_AGENTS[*]}" >&2
  } </dev/null 2>&1 |
    while IFS= read -r note; do
      # A message needs the client showing this session: with no -c, tmux picks
      # a client of its own and can write to an unrelated session's status line.
      # The attach is still in flight for the first notes, so wait up to 5s.
      client=""
      for _ in 1 2 3 4 5 6 7 8 9 10; do
        client=$(tmux list-clients -t "=$SESSION" -F '#{client_name}' 2>/dev/null | head -1)
        [ -n "$client" ] && break
        sleep 0.5
      done
      # tmux reads the text as a format string, so # is doubled to show as text.
      [ -n "$client" ] &&
        tmux display-message -d 10000 -c "$client" -- "${note//#/##}"
    done >/dev/null 2>&1 &
else
  launch_agents
  if [ ${#FAILED_AGENTS[@]} -gt 0 ]; then
    tmux kill-session -t "=$SESSION"
    die "agents failed to start; killed session $SESSION: ${FAILED_AGENTS[*]}"
  fi
fi
# The context watcher outlives this launch: it runs until the session is
# gone, compacting a pane whose context reaches compact-at tokens.
if [ "$COMPACT_AT" -gt 0 ]; then
  WATCH_PID_FILE="/tmp/peon-code-watch-$UID/$SESSION.pid"
  WATCH_PID=$(cat "$WATCH_PID_FILE" 2>/dev/null) || WATCH_PID=""
  if [[ $WATCH_PID =~ ^[1-9][0-9]*$ ]] && [ "$WATCH_PID" != "$$" ]; then
    WATCH_ARGS=$(ps -ww -o args= -p "$WATCH_PID" 2>/dev/null) || WATCH_ARGS=""
    case " $WATCH_ARGS " in
      *"/peon-code.sh watch $SESSION "*|*" peon-code.sh watch $SESSION "*)
        kill -TERM "$WATCH_PID" 2>/dev/null || true ;;
    esac
  fi
  nohup "$SCRIPT_DIR/peon-code.sh" watch "$SESSION" "$COMPACT_AT" >/dev/null 2>>"$BRIEF_DIR/watch.log" </dev/null &
fi
goto_session "$SESSION"
