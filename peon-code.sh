#!/usr/bin/env bash
# Start a tmux session of collaborating AI coding agents, one per pane,
# each launched with a prompt telling it to watch the other panes.
# Usage:
#   ./peon-code.sh                              session "peon-code", agents: claude codex
#   ./peon-code.sh <session>                    same agents, custom session name
#   ./peon-code.sh <session> <cmd> [<cmd> ...]  one pane per agent command
#                                             e.g. ./peon-code.sh lab claude codex claude
# Known agents get the right "interactive session + initial prompt" launch:
#   claude, codex   positional prompt, stay interactive (default passthrough)
#   copilot         -i <prompt>  (verified on this machine)
#   gemini, qwen    -i <prompt>  (documented; unverified on this machine)
# Any other command is passed through as-is: <cmd> <quoted-brief>.
set -euo pipefail

SESSION=${1:-peon-code}
[ $# -gt 0 ] && shift
AGENTS=("$@")
[ ${#AGENTS[@]} -eq 0 ] && AGENTS=(claude codex)
SESSION=${SESSION//[.:]/_}  # tmux rewrites . and : in session names
N=${#AGENTS[@]}

goto_session() {
  if [ -n "${TMUX:-}" ]; then
    exec tmux switch-client -t "=$SESSION"
  fi
  exec tmux attach -t "=$SESSION"
}

if tmux has-session -t "=$SESSION" 2>/dev/null; then
  goto_session
fi

# Roster line for every pane, shared by all briefs.
ROSTER=""
for i in "${!AGENTS[@]}"; do
  ROSTER+="pane $SESSION:agents.$i runs ${AGENTS[$i]}"$'\n'
done

# First agent is the new-session window; the rest are split off it.
tmux new-session -d -s "$SESSION" -n agents -c "$PWD"
tmux set -t "$SESSION" pane-base-index 0
for ((i = 1; i < N; i++)); do
  tmux split-window -t "$SESSION":agents -c "$PWD"
done
if [ "$N" -eq 2 ]; then
  tmux select-layout -t "$SESSION":agents even-horizontal
else
  tmux select-layout -t "$SESSION":agents tiled
fi

for i in "${!AGENTS[@]}"; do
  read -r -d '' BRIEF <<EOF || true
You are ${AGENTS[$i]} in pane $i of $N (this pane is $SESSION:agents.$i), one of $N AI coding agents collaborating side-by-side in tmux session "$SESSION". The panes are:
$ROSTER
You should always monitor the other agents' messages for collaboration. To read another agent's latest output, run: tmux capture-pane -pt $SESSION:agents.<other-index> -S -100. To send another agent a message, run: tmux send-keys -t $SESSION:agents.<other-index> 'your message' && sleep 1 && tmux send-keys -t $SESSION:agents.<other-index> Enter. The Enter must be a separate send-keys after the sleep, or the receiver's TUI treats it as pasted text and never submits. Check the other panes before starting a task and after finishing one, coordinate to avoid duplicate or conflicting edits.
EOF
  Q=$(printf %q "$BRIEF")
  # Map known CLIs to their interactive-session-with-initial-prompt syntax.
  # First token is the binary; trailing user args are preserved before the flag.
  case "${AGENTS[$i]%% *}" in
    copilot)     LAUNCH="${AGENTS[$i]} -i $Q" ;;  # -i starts the interactive TUI and runs the prompt
    gemini|qwen) LAUNCH="${AGENTS[$i]} -i $Q" ;;  # unverified on this machine
    *)           LAUNCH="${AGENTS[$i]} $Q" ;;     # claude, codex, anything else: positional prompt, stays interactive
  esac
  tmux send-keys -t "$SESSION":agents."$i" "$LAUNCH" Enter
done

goto_session
