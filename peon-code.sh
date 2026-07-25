#!/usr/bin/env bash
# Start a tmux session of collaborating AI coding agents, one per pane,
# each launched with a prompt telling it to watch the other panes.
# Usage:
#   ./peon-code.sh [-c file] [<session>] [<cmd> ...]
#   ./peon-code.sh dismiss
#   ./peon-code.sh msg <name|all> 'text'
#   ./peon-code.sh uninstall [bin-dir]
#   ./peon-code.sh -h
# Team resolution: CLI agent commands > -c file > ./peon-code.conf >
# ~/.config/peon-code/peon-code.conf > claude codex.
# Known agents get the right "interactive session + initial prompt" launch:
#   claude          launched bare, brief pasted in once its TUI is up
#   codex           positional prompt, stays interactive (default passthrough)
#   copilot         -i <prompt>  (verified on this machine)
#   gemini, qwen    -i <prompt>  (documented; unverified on this machine)
# Any other command is passed through as-is: <cmd> <quoted-brief>.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
DEFAULT_CONF=peon-code.conf
TASK_BOARD=.peon-code-task.md

usage() {
  cat <<'USAGE'
peon-code.sh [-c file] [<session>] [<cmd> ...]  start or attach a team
                                                (session defaults to the current directory name)
peon-code.sh dismiss                            kill the tmux server
peon-code.sh msg <name|all> 'text'              send text to an agent pane
peon-code.sh uninstall [bin-dir]                remove the install.sh symlink
peon-code.sh -h                                 this help

  -c file   agent config file (default ./peon-code.conf, then
            ~/.config/peon-code/peon-code.conf, if present)

Config file: one agent per line, "name command... role".
The role is required; use - for no role. A bare role name reads
<script dir>/roles/<name>.md; a role token with a / is a file path,
relative paths resolving against the config file's directory.
Full-line # comments and blank lines are skipped.

  boss   claude               manager
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

# The @peon_name pane option carries the agent name: unlike the pane title,
# an app cannot overwrite it. Panes without it are not ours and are skipped,
# as are panes running a shell: pasted text there would run as commands.
list_agent_panes() {
  local id cmd name
  tmux list-panes -a -F '#{pane_id} #{pane_current_command} #{@peon_name}' 2>/dev/null |
    while read -r id cmd name; do
      [ -n "$name" ] || continue
      case $cmd in
        sh|bash|zsh|fish|dash|ksh) continue ;;
      esac
      echo "$id $name"
    done
}

# Paste stdin into a pane, then press Enter as a separate call. Bracketed
# paste keeps a multi-line block in the input line instead of submitting it
# early; long lines sent with send-keys are cut at the tty line limit.
paste_to_pane() {
  local pane=$1
  tmux load-buffer -
  tmux paste-buffer -dpt "$pane"
  sleep 1
  tmux send-keys -t "$pane" Enter
}

# Wait until a pane's shell has started: it reports a shell, or has drawn
# something. Bounded, so a pane that never reports still lets the run finish.
wait_shell_ready() {
  local pane=$1 i cur out
  for ((i = 0; i < 50; i++)); do
    cur=$(tmux display -pt "$pane" '#{pane_current_command}' 2>/dev/null) || cur=""
    case $cur in
      sh|bash|zsh|fish|dash|ksh) return 0 ;;
    esac
    out=$(tmux capture-pane -pt "$pane" 2>/dev/null) || out=""
    [ -n "${out//[[:space:]]/}" ] && return 0
    sleep 0.2
  done
}

# Wait until the agent CLI has replaced the shell in a pane.
wait_agent_ready() {
  local pane=$1 i cur
  for ((i = 0; i < 100; i++)); do
    cur=$(tmux display -pt "$pane" '#{pane_current_command}' 2>/dev/null) || cur=""
    case $cur in
      sh|bash|zsh|fish|dash|ksh|"") sleep 0.2 ;;
      *) return 0 ;;
    esac
  done
}

# Wait until the claude prompt line is drawn and the pane has stopped
# changing: a capture holds a line starting with the prompt marker and
# matches the capture 0.3s before.
# ponytail: the 30s ceiling ends the wait when a spinner keeps redrawing or
# the prompt never shows, as on a trust dialog.
wait_pane_settled() {
  local pane=$1 i prev="" cur
  for ((i = 0; i < 100; i++)); do
    cur=$(tmux capture-pane -pt "$pane" 2>/dev/null) || cur=""
    if [[ $cur == *❯* ]] && [ "$cur" = "$prev" ]; then
      return 0
    fi
    prev=$cur
    sleep 0.3
  done
}

cmd_dismiss() {
  local sessions
  if ! sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null); then
    echo "peon-code: no tmux server running"
    exit 0
  fi
  echo "peon-code: killing tmux server, sessions: $(echo "$sessions" | tr '\n' ' ')"
  tmux kill-server
}

cmd_msg() {
  local target=${1:-} text=${2:-} panes id name
  [ -n "$target" ] && [ -n "$text" ] || die "usage: peon-code.sh msg <name|all> 'text'"
  panes=$(list_agent_panes) || true
  [ -n "$panes" ] || die "no agent panes found"
  local ids=()
  while read -r id name; do
    if [ "$target" = all ] || [ "$target" = "$name" ]; then
      ids+=("$id")
    fi
  done <<<"$panes"
  if [ ${#ids[@]} -eq 0 ]; then
    echo "peon-code: no pane named $target. Agent panes found:" >&2
    while read -r id name; do
      echo "  $name $id" >&2
    done <<<"$panes"
    exit 1
  fi
  printf '%s' "[from user] $text" | tmux load-buffer -b peon-msg -
  for id in "${ids[@]}"; do
    tmux paste-buffer -b peon-msg -t "$id" -p
  done
  sleep 1
  for id in "${ids[@]}"; do
    tmux send-keys -t "$id" Enter
  done
  tmux delete-buffer -b peon-msg
  echo "peon-code: sent to ${#ids[@]} pane(s)"
}

case "${1:-}" in
  dismiss) cmd_dismiss; exit 0 ;;
  msg)  shift; cmd_msg "$@"; exit 0 ;;
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

NAMES=()
CMDS=()
ROLES=()  # resolved role file path, empty for no role

# Role token: - is none, a token with / is a path (relative to the config
# file's directory), a bare name is <script dir>/roles/<name>.md.
resolve_role() {
  local role=$1 conf_dir=$2
  case $role in
    -)   echo "" ;;
    /*)  echo "$role" ;;
    */*) echo "$conf_dir/$role" ;;
    *)   echo "$SCRIPT_DIR/roles/$role.md" ;;
  esac
}

role_label() {
  local path=$1 base
  [ -n "$path" ] || { echo "none"; return; }
  base=${path##*/}
  echo "${base%.md}"
}

read_conf() {
  local conf=$1 conf_dir line lineno=0 n name cmd role path known
  conf_dir=$(cd -- "$(dirname -- "$conf")" && pwd)
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
    local tokens=()
    read -ra tokens <<<"$line"
    n=${#tokens[@]}
    [ "$n" -ge 3 ] || die "$conf line $lineno: need name, command, and role (got $n): $line"
    name=${tokens[0]}
    role=${tokens[$((n - 1))]}
    cmd="${tokens[*]:1:$((n - 2))}"
    [[ $name =~ ^[A-Za-z0-9_-]+$ ]] || die "$conf line $lineno: name \"$name\" must be letters, digits, _ or -"
    for known in ${NAMES[@]+"${NAMES[@]}"}; do
      if [ "$known" = "$name" ]; then
        die "$conf line $lineno: name \"$name\" is used twice"
      fi
    done
    path=$(resolve_role "$role" "$conf_dir")
    [ -z "$path" ] || [ -f "$path" ] || die "$conf line $lineno: role file not found: $path"
    NAMES+=("$name")
    CMDS+=("$cmd")
    ROLES+=("$path")
  done <"$conf"
  [ ${#NAMES[@]} -gt 0 ] || die "$conf has no agents"
}

SESSION=${1:-${PWD##*/}}       # default session name: current directory
SESSION=${SESSION:-peon-code}  # PWD is /
[ $# -gt 0 ] && shift
if [ $# -gt 0 ]; then
  # CLI agent commands win; the name is the command string, no role.
  for arg in "$@"; do
    case $arg in
      -*) die "agent command \"$arg\" starts with -; put options before the session name" ;;
    esac
    NAMES+=("$arg")
    CMDS+=("$arg")
    ROLES+=("")
  done
else
  # Resolution: ./peon-code.conf, then the user fallback, then claude codex.
  if [ -z "$CONF" ]; then
    CONF=$DEFAULT_CONF
    [ -f "$CONF" ] || CONF="$HOME/.config/peon-code/peon-code.conf"
  fi
  if [ -f "$CONF" ]; then
    read_conf "$CONF"
  elif [ "$CONF_GIVEN" -eq 1 ]; then
    die "config file not found: $CONF"
  else
    for arg in claude codex; do
      NAMES+=("$arg")
      CMDS+=("$arg")
      ROLES+=("")
    done
  fi
fi

SESSION=${SESSION//[.:]/_}  # tmux rewrites . and : in session names
N=${#NAMES[@]}

goto_session() {
  # No TTY means a headless caller: build the session, print how to reach it.
  if [ ! -t 0 ]; then
    echo "peon-code: session $SESSION is ready. Attach with: tmux attach -t $SESSION"
    exit 0
  fi
  if [ -n "${TMUX:-}" ]; then
    exec tmux switch-client -t "=$SESSION"
  fi
  exec tmux attach -t "=$SESSION"
}

if tmux has-session -t "=$SESSION" 2>/dev/null; then
  goto_session
fi

if [ ! -f "$TASK_BOARD" ]; then
  cat >"$TASK_BOARD" <<'BOARD'
# task board

| who | task | files | status |
|-----|------|-------|--------|
BOARD
fi

# First agent is the new-session window; the rest are split off it.
# Retile after each split so large teams do not hit "pane too small".
tmux new-session -d -s "$SESSION" -n agents -c "$PWD"
# Session-scoped, so the terminal tab caption is the session name only here.
tmux set -t "$SESSION" set-titles on
tmux set -t "$SESSION" set-titles-string '#S'
for ((i = 1; i < N; i++)); do
  tmux split-window -t "$SESSION":agents -c "$PWD"
  tmux select-layout -t "$SESSION":agents tiled >/dev/null
done
if [ "$N" -eq 2 ]; then
  tmux select-layout -t "$SESSION":agents even-horizontal >/dev/null
fi

# Stable pane IDs survive pane moves and layout changes, unlike indices.
PANE_IDS=()
while read -r pane_id; do
  PANE_IDS+=("$pane_id")
done < <(tmux list-panes -t "$SESSION:agents" -F '#{pane_id}')

# A failed split leaves a half-built session; drop the one this run made.
if [ ${#PANE_IDS[@]} -ne "$N" ]; then
  tmux kill-session -t "=$SESSION"
  die "made ${#PANE_IDS[@]} panes for $N agents; killed session $SESSION"
fi

for i in "${!NAMES[@]}"; do
  tmux set -pt "${PANE_IDS[$i]}" @peon_name "${NAMES[$i]}"
  tmux select-pane -t "${PANE_IDS[$i]}" -T "${NAMES[$i]}"  # border label only
  wait_shell_ready "${PANE_IDS[$i]}"
done

# Roster line for every pane, shared by all briefs.
ROSTER=""
for i in "${!NAMES[@]}"; do
  ROSTER+="pane ${PANE_IDS[$i]}: ${NAMES[$i]} (${CMDS[$i]}) - $(role_label "${ROLES[$i]}")"$'\n'
done

for i in "${!NAMES[@]}"; do
  WHO="${NAMES[$i]} (${CMDS[$i]})"
  [ "${NAMES[$i]}" = "${CMDS[$i]}" ] && WHO="${NAMES[$i]}"
  ROLE_SECTION=""
  if [ -n "${ROLES[$i]}" ]; then
    ROLE_SECTION="Your role: $(role_label "${ROLES[$i]}")
$(cat "${ROLES[$i]}")
"
  fi
  read -r -d '' BRIEF <<EOF || true
You are $WHO in pane $i of $N (this pane is ${PANE_IDS[$i]}), one of $N AI coding agents collaborating side-by-side in tmux session "$SESSION". The panes are:
$ROSTER
$ROLE_SECTION
To read another agent's latest output, run: tmux capture-pane -pt <other-pane-id> -S -100. To send another agent a message, run: tmux send-keys -t <other-pane-id> -l -- 'your message' && sleep 1 && tmux send-keys -t <other-pane-id> Enter. The Enter must be a separate send-keys after the sleep, or the receiver's TUI treats it as pasted text and never submits. Start every message you send with [from ${NAMES[$i]} ${PANE_IDS[$i]}] so receivers know who sent it and can tell messages apart from scraped output. Avoid single quotes/apostrophes in messages, since the message is wrapped in single quotes in the send-keys command. Message another agent only when: (1) you start a task, to claim the files you will touch; (2) you finish a task, with a one-line summary; (3) you are blocked or detect a conflicting edit. Do not message for routine progress or individual file saves. Check the other panes at task start and task end only.

The task board is $TASK_BOARD in the working directory, a table of who | task | files | status. Record your task claims and finishes there, and read it before claiming files someone else already listed. Messages are alerts; the board is the record that lasts.

Rules:
1. Task intake: the user assigns work by typing into the manager pane (pane 0 if the team has no manager). That agent splits the work onto the task board and assigns it; every other agent waits for a board entry or a message instead of inventing work at launch. The agent that split the work posts the final summary to the user.
2. Git discipline: never run git add -A, never commit, and never run destructive git commands unless the user asks. Stage only the files you claimed. Only one agent touches git at a time.
3. Look before sending: capture the target pane first. If it shows a dialog or a menu (numbered choices, a yes/no question), wait and retry later; never type into it. Text on an agent's input line is not a dialog: every agent TUI draws a greyed hint or suggestion there while the box is empty, and a pasted message appends to the box rather than replacing it. Send anyway.
4. Dead-pane guard: if tmux display -pt <id> '#{pane_current_command}' shows a shell, that agent is gone. Do not send, because your text would run as shell commands. Tell the user instead.
5. Literal sends: use tmux send-keys -t <id> -l -- 'message' so key names and leading dashes are not read as keys. Enter still goes separately after a 1 second sleep.
6. No idle deadlocks: if you are blocked, message once, work on something else, then re-check once. After that, proceed on your best judgment or tell the user.
7. Rate limits: if you hit a usage limit, note it and the reset time on the task board so the others can reassign the work.
EOF
  Q=$(printf %q "$BRIEF")
  # Map known CLIs to their interactive-session-with-initial-prompt syntax.
  # First token is the binary; trailing user args are preserved before the flag.
  case "${CMDS[$i]%% *}" in
    claude)      LAUNCH="${CMDS[$i]}" ;;        # bare, keeping user args; the brief follows the TUI
    copilot)     LAUNCH="${CMDS[$i]} -i $Q" ;;  # -i starts the interactive TUI and runs the prompt
    gemini|qwen) LAUNCH="${CMDS[$i]} -i $Q" ;;  # unverified on this machine
    *)           LAUNCH="${CMDS[$i]} $Q" ;;     # codex, anything else: positional prompt, stays interactive
  esac
  printf '%s' "$LAUNCH" | paste_to_pane "${PANE_IDS[$i]}"
  if [ "${CMDS[$i]%% *}" = claude ]; then
    wait_agent_ready "${PANE_IDS[$i]}"
    wait_pane_settled "${PANE_IDS[$i]}"  # let the TUI finish drawing before it takes input
    printf '%s' "$BRIEF" | paste_to_pane "${PANE_IDS[$i]}"
  fi
done

goto_session
