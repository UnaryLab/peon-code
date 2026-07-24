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

# First agent is the new-session window; the rest are split off it.
tmux new-session -d -s "$SESSION" -n agents -c "$PWD"
for ((i = 1; i < N; i++)); do
  tmux split-window -t "$SESSION":agents -c "$PWD"
done
if [ "$N" -eq 2 ]; then
  tmux select-layout -t "$SESSION":agents even-horizontal
else
  tmux select-layout -t "$SESSION":agents tiled
fi

# Stable pane IDs survive pane moves and layout changes, unlike indices.
PANE_IDS=($(tmux list-panes -t "$SESSION:agents" -F '#{pane_id}'))

# Roster line for every pane, shared by all briefs.
ROSTER=""
for i in "${!AGENTS[@]}"; do
  ROSTER+="pane ${PANE_IDS[$i]} runs ${AGENTS[$i]}"$'\n'
done

for i in "${!AGENTS[@]}"; do
  read -r -d '' BRIEF <<EOF || true
You are ${AGENTS[$i]} in pane $i of $N (this pane is ${PANE_IDS[$i]}), one of $N AI coding agents collaborating side-by-side in tmux session "$SESSION". The panes are:
$ROSTER
To read another agent's latest output, run: tmux capture-pane -pt <other-pane-id> -S -100. To send another agent a message, run: tmux send-keys -t <other-pane-id> 'your message' && sleep 1 && tmux send-keys -t <other-pane-id> Enter. The Enter must be a separate send-keys after the sleep, or the receiver's TUI treats it as pasted text and never submits. Start every message you send with [from ${AGENTS[$i]} ${PANE_IDS[$i]}] so receivers know who sent it and can tell messages apart from scraped output. Avoid single quotes/apostrophes in messages, since the message is wrapped in single quotes in the send-keys command. Message another agent only when: (1) you start a task, to claim the files you will touch; (2) you finish a task, with a one-line summary; (3) you are blocked or detect a conflicting edit. Do not message for routine progress or individual file saves. Check the other panes at task start and task end only.
EOF
  Q=$(printf %q "$BRIEF")
  # Map known CLIs to their interactive-session-with-initial-prompt syntax.
  # First token is the binary; trailing user args are preserved before the flag.
  case "${AGENTS[$i]%% *}" in
    copilot)     LAUNCH="${AGENTS[$i]} -i $Q" ;;  # -i starts the interactive TUI and runs the prompt
    gemini|qwen) LAUNCH="${AGENTS[$i]} -i $Q" ;;  # unverified on this machine
    *)           LAUNCH="${AGENTS[$i]} $Q" ;;     # claude, codex, anything else: positional prompt, stays interactive
  esac
  tmux send-keys -t "${PANE_IDS[$i]}" "$LAUNCH" Enter
done

goto_session
