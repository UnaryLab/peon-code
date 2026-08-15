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
#   ./peon-code.sh clear [<name|all>] [<session>]
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
#   grok            positional prompt, stays interactive (verified on this machine); resumes with --resume <id>
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
                                                grok, gemini, qwen)
peon-code.sh dismiss [<session>]                kill one session
                                                (session defaults to the current directory name)
peon-code.sh msg <name|all> 'text' [<session>]  send text to an agent pane
                                                (session defaults to the current directory name)
peon-code.sh send <pane-id> 'text'|-            agent to agent: paste into a pane and
                                                submit it; a blocked pane (typed text,
                                                dialog, menu, copy mode) is retried up
                                                to 10 times over ~10s before exiting
                                                non-zero (- reads the message from stdin)
peon-code.sh rebrief <name|all> [<session>]     send an agent its launch brief again,
                                                for after it compacts its conversation
                                                (session defaults to the current directory name)
peon-code.sh compact [<name|all>] [<session>]   send /compact to an agent pane, then send
                                                its brief again once compaction ends,
                                                skipping any blocked pane (typed text,
                                                dialog, menu, copy mode)
                                                (name and session default to all and the
                                                current directory name)
peon-code.sh clear [<name|all>] [<session>]     send /clear to an agent pane, then send
                                                its brief again, skipping any blocked
                                                pane (typed text, dialog, menu, copy mode)
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
# shellcheck source=lib/commands.sh
source "$SCRIPT_DIR/lib/commands.sh"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=lib/brief.sh
source "$SCRIPT_DIR/lib/brief.sh"

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
  clear) shift; cmd_clear "$@"; exit 0 ;;
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
  printf '%s\n' "$BOARD_HEADER" >"$TASK_BOARD"
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

# Only the main agent launches with full git. Every other claude pane
# launches with --settings pointing at this deny file; the deny rules bind
# the pane and every subagent it spawns, which role prose does not.
DENY_SETTINGS="$BRIEF_DIR/deny-git.json"
{
  printf '{\n  "permissions": {\n    "deny": [\n'
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
  ROSTER+="pane ${PANE_IDS[$i]}: ${NAMES[$i]} (${CMDS[$i]}) - $(role_label "${ROLES[$i]}")"$'\n'
done

for i in "${!NAMES[@]}"; do
  BRIEF=$(build_brief "$i")
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
    claude)
      # A claude pane that is not the main agent launches with the deny
      # settings, unless its own args already pass --settings, which wins:
      # claude reads one --settings and the second would be lost.
      SETTINGS=""
      if [ "$i" -ne "$MAIN" ]; then
        case "$ARGS " in
          *" --settings "*|*" --settings="*)
            echo "peon-code: ${NAMES[$i]} passes its own --settings, so it gets no git deny file" >&2 ;;
          *) SETTINGS=" --settings $(printf %q "$DENY_SETTINGS")" ;;
        esac
        case "$ARGS " in
          *" --dangerously-skip-permissions "*)
            echo "peon-code: ${NAMES[$i]} passes --dangerously-skip-permissions, so the git deny file has no effect" >&2 ;;
        esac
      fi
      LAUNCH="$BIN${RID:+ --resume $RID}$ARGS$SETTINGS" ;;  # bare, keeping user args; the brief follows the TUI
    codex)       LAUNCH="$BIN${RID:+ resume $RID}$ARGS $Q" ;; # positional prompt, stays interactive
    grok)        LAUNCH="$BIN${RID:+ --resume $RID}$ARGS $Q" ;; # positional prompt, stays interactive
    copilot)     LAUNCH="$BIN${RID:+ --resume=$RID}$ARGS -i $Q" ;;  # -i starts the interactive TUI and runs the prompt
    gemini|qwen) LAUNCH="$BIN${RID:+ --resume $RID}$ARGS -i $Q" ;;  # unverified on this machine
    *)           LAUNCH="${CMDS[$i]} $Q" ;;     # anything else: positional prompt
  esac
  # The pane is still at its shell, whose prompt peon-code cannot predict, so
  # the box holds no text to check against: Enter follows the paste directly.
  if printf '%s' "$LAUNCH" | paste_only "${PANE_IDS[$i]}"; then
    sleep 1
    tmux send-keys -t "${PANE_IDS[$i]}" Enter
  else
    echo "peon-code: tmux refused the command line for ${NAMES[$i]} ${PANE_IDS[$i]}" >&2
  fi
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
      PASTE_RC=0
      printf '%s' "$BRIEF" | paste_to_pane "${PANE_IDS[$i]}" || PASTE_RC=$?
      case $PASTE_RC in
        1) echo "peon-code: tmux refused the brief for ${NAMES[$i]} ${PANE_IDS[$i]}. Paste it by hand: $BRIEF_FILE" >&2 ;;
        2) echo "peon-code: no Enter sent to ${NAMES[$i]} ${PANE_IDS[$i]}: the brief is in its box for you to submit" >&2 ;;
      esac
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
