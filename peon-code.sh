#!/usr/bin/env bash
# Start a tmux session of collaborating AI coding agents, one per pane,
# each launched with a prompt telling it to watch the other panes.
# Usage:
#   ./peon-code.sh [-c file] [<session>] [<cmd> ...]
#   ./peon-code.sh resume [<session>] [<cmd> ...]
#   ./peon-code.sh dismiss [<session>]
#   ./peon-code.sh msg <name|all> 'text' [<session>]
#   ./peon-code.sh send <pane-id> 'text'|-
#   ./peon-code.sh rebrief <name|all> [<session>]
#   ./peon-code.sh compact [<name|all>] [<session>]
#   ./peon-code.sh list
#   ./peon-code.sh uninstall [bin-dir]
#   ./peon-code.sh -h
# Team resolution: CLI agent commands > -c file > ./peon-code.conf >
# ~/.config/peon-code/peon-code.conf > claude codex.
# Known agents get the right "interactive session + initial prompt" launch:
#   claude          launched bare, brief pasted in once its TUI is up; resumes with --resume <id>,
#                   answering a "Resume from summary" picker with its summary default
#   codex           positional prompt, stays interactive; resumes with resume <id>
#   copilot         -i <prompt>  (verified on this machine); resumes with --resume=<id>
#   gemini, qwen    -i <prompt>  (documented; unverified on this machine); resume with --resume <id>
# Any other command is passed through as-is: <cmd> <quoted-brief>.
set -euo pipefail

# Resolve symlinks without readlink -f, which macOS lacks before 12.3.
script_path=${BASH_SOURCE[0]}
while [ -L "$script_path" ]; do
  link_target=$(readlink "$script_path")
  case $link_target in
    /*) script_path=$link_target ;;
    *)  script_path=$(dirname -- "$script_path")/$link_target ;;
  esac
done
SCRIPT_DIR=$(cd -- "$(dirname -- "$script_path")" && pwd)
DEFAULT_CONF=peon-code.conf
TASK_BOARD=.peon-code-task.md

usage() {
  cat <<'USAGE'
peon-code.sh [-c file] [<session>] [<cmd> ...]  start or attach a team
                                                (session defaults to the current directory name)
peon-code.sh resume [<session>] [<cmd> ...]     same, each agent reopening its last
                                                conversation (claude, codex, copilot,
                                                gemini, qwen)
peon-code.sh dismiss [<session>]                kill one session
                                                (session defaults to the current directory name)
peon-code.sh msg <name|all> 'text' [<session>]  send text to an agent pane
                                                (session defaults to the current directory name)
peon-code.sh send <pane-id> 'text'|-            agent to agent: paste into a pane and
                                                submit it, refused while that pane's
                                                input box holds typed text
                                                (- reads the message from stdin)
peon-code.sh rebrief <name|all> [<session>]     send an agent its launch brief again,
                                                for after it compacts its conversation
                                                (session defaults to the current directory name)
peon-code.sh compact [<name|all>] [<session>]   send /compact to an agent pane, then send
                                                its brief again once compaction ends,
                                                skipping any pane whose input box holds
                                                typed text
                                                (name and session default to all and the
                                                current directory name)
peon-code.sh list                               agent panes of every session
peon-code.sh uninstall [bin-dir]                remove the install.sh symlink
peon-code.sh -h                                 this help

  -c file   agent config file (default ./peon-code.conf, then
            ~/.config/peon-code/peon-code.conf, if present)

Config file: one agent per line, "name command... role".
The role is required; use - for no role. A bare role name reads
<script dir>/roles/<name>.md; a role token with a / is a file path,
relative paths resolving against the config file's directory.
A leading * on a name marks the main agent, whose pane gets the big
left slot; without it, the first manager, else the first agent.
Full-line # comments and blank lines are skipped.

  *boss  claude               manager
  impl   codex --model gpt-5.6-sol  implementer
  fast   codex                -
  weird  claude               ./my-roles/chaos.md

Team resolution: CLI agent commands > -c file > ./peon-code.conf >
~/.config/peon-code/peon-code.conf > claude codex.
USAGE
}

die() {
  echo "peon-code: $*" >&2
  exit 1
}

# shellcheck source=lib/tmux.sh
source "$SCRIPT_DIR/lib/tmux.sh"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"

CONF=""
CONF_GIVEN=0
while getopts ":c:h" opt; do
  case $opt in
    c) CONF=$OPTARG; CONF_GIVEN=1 ;;
    h) usage; exit 0 ;;
    :) die "option -$OPTARG needs a file" ;;
    *) usage >&2; die "unknown option -$OPTARG" ;;
  esac
done
shift $((OPTIND - 1))

RESUME=0
case "${1:-}" in
  resume) RESUME=1; shift ;;
  dismiss) shift; cmd_dismiss "$@"; exit 0 ;;
  msg)  shift; cmd_msg "$@"; exit 0 ;;
  send) shift; cmd_send "$@"; exit 0 ;;
  rebrief) shift; cmd_rebrief "$@"; exit 0 ;;
  compact) shift; cmd_compact "$@"; exit 0 ;;
  list) [ $# -eq 1 ] || die "list takes no arguments"; cmd_list; exit 0 ;;
  uninstall)
    LINK="${2:-$HOME/.local/bin}/peon-code"
    if [ -L "$LINK" ] && [ "$(readlink "$LINK")" = "$SCRIPT_DIR/peon-code.sh" ]; then
      rm "$LINK" && echo "removed: $LINK"
    elif [ -e "$LINK" ]; then
      echo "not removing $LINK: it does not point at $SCRIPT_DIR/peon-code.sh" >&2
      exit 1
    else
      echo "nothing to remove: $LINK does not exist"
    fi
    exit 0 ;;
esac

SESSION=$(session_name "${1:-}")  # default session name: current directory
[ $# -gt 0 ] && shift
load_team "$@"
N=${#NAMES[@]}

if tmux has-session -t "=$SESSION" 2>/dev/null; then
  is_peon_session "$SESSION" || die "session $SESSION already exists and was not created by peon-code"
  goto_session "$SESSION"
fi

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
  cat >"$TASK_BOARD" <<'BOARD'
# task board

| who | task | files | status |
|-----|------|-------|--------|
BOARD
fi

# The pane the user types into gets the main slot: the agent marked * in the
# config, else the first manager, else pane 0. Brief rule 1 names this pane
# as the task-intake pane.
MAIN=$MAIN_INDEX
if [ "$MAIN" -lt 0 ]; then
  MAIN=0
  for i in "${!ROLES[@]}"; do
    if [ "$(role_label "${ROLES[$i]}")" = manager ]; then
      MAIN=$i
      break
    fi
  done
fi

create_agent_session "$SESSION" "$N" "$MAIN"
FAILED_AGENTS=()
for i in "${!NAMES[@]}"; do
  tmux set -pt "${PANE_IDS[$i]}" @peon_name "${NAMES[$i]}"
  tmux select-pane -t "${PANE_IDS[$i]}" -T "${NAMES[$i]}"  # border label only
  wait_shell_ready "${PANE_IDS[$i]}"
done

# Briefs go to files: pasting one on a shell command line would fill the
# pane with thousands of escaped characters before the agent even starts.
# The directory is left for the OS to clear, since the launcher
# ends in exec and the panes read the files after it is gone.
BRIEF_DIR=$(mktemp -d "${TMPDIR:-/tmp}/peon-code.XXXXXX")

# Roster line for every pane, shared by all briefs.
ROSTER=""
for i in "${!NAMES[@]}"; do
  ROSTER+="pane ${PANE_IDS[$i]}: ${NAMES[$i]} (${CMDS[$i]}) - $(role_label "${ROLES[$i]}")"$'\n'
done

for i in "${!NAMES[@]}"; do
  WHO="${NAMES[$i]} (${CMDS[$i]})"
  [ "${NAMES[$i]}" = "${CMDS[$i]}" ] && WHO="${NAMES[$i]}"
  # Message prefix: CLI binary plus agent name; just the binary when the
  # name is the command itself (a roleless CLI team).
  MSG_FROM="${CMDS[$i]%% *} ${NAMES[$i]}"
  [ "${NAMES[$i]}" = "${CMDS[$i]}" ] && MSG_FROM="${CMDS[$i]%% *}"
  ROLE_SECTION=""
  if [ -n "${ROLES[$i]}" ]; then
    ROLE_SECTION="Your role: $(role_label "${ROLES[$i]}")
$(cat "${ROLES[$i]}")
"
  fi
  read -r -d '' BRIEF <<EOF || true
You are $WHO, agent ${NAMES[$i]} of peon-code session $SESSION, in pane $i of $N (this pane is ${PANE_IDS[$i]}), one of $N AI coding agents collaborating side-by-side in tmux. The panes are:
$ROSTER
$ROLE_SECTION
To read another agent's latest output, run: tmux capture-pane -pt <other-pane-id> -S -100. To send another agent a message, run this, with the message on the lines between the markers:
$SCRIPT_DIR/peon-code.sh send <other-pane-id> - <<'PEON'
your message
PEON
The message is read from stdin, so quotes and apostrophes in it stay out of your shell. It pastes the message and presses Enter only once the target's input box holds it, and it exits non-zero without pasting when that box already holds typed text. Start every message you send with [from $MSG_FROM ${PANE_IDS[$i]}] so receivers know who sent it and can tell messages apart from scraped output. Message another agent only when: (1) you start a task, to claim the files you will touch; (2) you finish a task, with a one-line summary; (3) you are blocked or detect a conflicting edit. Do not message for routine progress or individual file saves. Check the other panes at task start and task end only.

The task board is $TASK_BOARD in the working directory, a table of who | task | files | status; create it with that header row if it is not there. Record your task claims and finishes there, and read it before claiming files someone else already listed. Messages are alerts; the board is the record that lasts.

Rules:
1. Task intake: the user assigns work by typing into the ${NAMES[$MAIN]} pane (${PANE_IDS[$MAIN]}). That agent splits the work onto the task board and assigns it; every other agent waits for a board entry or a message instead of inventing work at launch. The agent that split the work posts the final summary to the user.
2. Git discipline: never run git add -A, never commit, and never run destructive git commands unless the user asks. Stage only the files you claimed. Only one agent touches git at a time.
3. Held sends: send makes the box check and the paste back to back in one run, and presses Enter only when the box holds exactly your message. When it fails with a busy message, the target was mid-dialog, mid-menu, in copy mode, or holding typed text: wait, do something else, and retry later. Never paste into that pane by hand.
4. Dead-pane guard: if tmux display -pt <id> '#{pane_current_command}' shows a shell, that agent is gone. Do not send, because your text would run as shell commands. Tell the user instead.
5. No idle deadlocks: if you are blocked, message once, work on something else, then re-check once. After that, proceed on your best judgment or tell the user.
6. Rate limits: if you hit a usage limit, note it and the reset time on the task board so the others can reassign the work.
EOF
  BRIEF_FILE="$BRIEF_DIR/$i.md"  # by index: a CLI-team name is the command, which can hold / or repeat
  printf '%s' "$BRIEF" >"$BRIEF_FILE"
  # rebrief finds the brief through this pane option.
  tmux set -pt "${PANE_IDS[$i]}" @peon_brief "$BRIEF_FILE"
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
  case "$BIN" in
    claude)      LAUNCH="$BIN${RID:+ --resume $RID}$ARGS" ;;  # bare, keeping user args; the brief follows the TUI
    codex)       LAUNCH="$BIN${RID:+ resume $RID}$ARGS $Q" ;; # positional prompt, stays interactive
    copilot)     LAUNCH="$BIN${RID:+ --resume=$RID}$ARGS -i $Q" ;;  # -i starts the interactive TUI and runs the prompt
    gemini|qwen) LAUNCH="$BIN${RID:+ --resume $RID}$ARGS -i $Q" ;;  # unverified on this machine
    *)           LAUNCH="${CMDS[$i]} $Q" ;;     # anything else: positional prompt
  esac
  printf '%s' "$LAUNCH" | paste_to_pane "${PANE_IDS[$i]}"
  if ! wait_agent_ready "${PANE_IDS[$i]}"; then
    FAILED_AGENTS+=("${NAMES[$i]}")
    continue
  fi
  if [ "${CMDS[$i]%% *}" = claude ]; then
    # A resumed pane may open on the summary picker; take its default,
    # "Resume from summary", then allow for the compaction that starts:
    # 400 settle tries (~2 min) instead of the usual 100.
    [ -z "$RID" ] || answer_resume_picker "${PANE_IDS[$i]}"
    # An unsettled pane is showing a dialog or still starting; pasting there
    # would answer the dialog blindly, which the brief tells agents never to do.
    if wait_pane_settled "${PANE_IDS[$i]}" "${RID:+400}"; then
      printf '%s' "$BRIEF" | paste_to_pane "${PANE_IDS[$i]}"
    else
      echo "peon-code: ${NAMES[$i]} is still on a dialog or starting up. Answer it, then paste the brief: $BRIEF_FILE" >&2
    fi
  fi
done

if [ ${#FAILED_AGENTS[@]} -gt 0 ]; then
  tmux kill-session -t "=$SESSION"
  die "agents failed to start; killed session $SESSION: ${FAILED_AGENTS[*]}"
fi

goto_session "$SESSION"
