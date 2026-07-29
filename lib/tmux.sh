# shellcheck shell=bash

# Session name for a directory: the given name, else the current directory.
# tmux rewrites . and : in session names, so match what it stores.
session_name() {
  local s=${1:-${PWD##*/}}
  s=${s:-peon-code}  # PWD is /
  printf '%s\n' "${s//[.:]/_}"
}

# The @peon_name pane option carries the agent name: unlike the pane title,
# an app cannot overwrite it. Panes without it are not ours and are skipped,
# as are panes running a shell: pasted text there would run as commands.
# With a session argument, only that session's panes; teams share agent
# names, so an unscoped match would reach every team on the server.
list_agent_panes() {
  local id cmd name scope=(-a)
  [ $# -gt 0 ] && scope=(-s -t "=$1")
  tmux list-panes "${scope[@]}" -F '#{pane_id} #{pane_current_command} #{@peon_name}' 2>/dev/null |
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
  local pane=$1 buffer="peon-code-$$-${1#%}"
  tmux load-buffer -b "$buffer" -
  tmux paste-buffer -b "$buffer" -dpt "$pane"
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
  return 1
}

# A resumed claude pane can open on a picker asking how to resume a large or
# old session; its default row is "Resume from summary (recommended)". Enter
# accepts that default, so the pane moves on instead of sitting on the dialog
# until the settle wait gives up. A pane that reaches the input line first
# never showed the picker, so the wait ends there. Always returns 0: a pane
# still drawing after the cap is left for wait_pane_settled to judge.
answer_resume_picker() {
  local pane=$1 i cur
  for ((i = 0; i < 50; i++)); do
    cur=$(tmux capture-pane -pt "$pane" 2>/dev/null) || cur=""
    if [[ $cur == *"Resume from summary"* ]]; then
      tmux send-keys -t "$pane" Enter
      return 0
    fi
    case $cur in
      *"Enter to confirm"*|*"❯ "[0-9]"."*) ;;  # some other menu: keep waiting
      *❯*) return 0 ;;                         # input line drawn: no picker
    esac
    sleep 0.3
  done
  return 0
}

# Wait until the claude prompt line is drawn and the pane has stopped
# changing: a capture holds a line starting with the prompt marker and
# matches the capture 0.3s before. A menu such as the folder-trust dialog
# draws the same marker on its selected row, so a capture holding a menu
# is never settled: the wait continues until the user answers it.
# ponytail: the 30s ceiling ends the wait when a spinner keeps redrawing,
# the prompt never shows, or the dialog goes unanswered; the caller then
# skips the paste rather than typing into whatever is on screen.
wait_pane_settled() {
  local pane=$1 tries=${2:-100} i prev="" cur
  for ((i = 0; i < tries; i++)); do
    cur=$(tmux capture-pane -pt "$pane" 2>/dev/null) || cur=""
    case $cur in
      *"Enter to confirm"*|*"❯ "[0-9]"."*) cur="" ;;  # a menu, not the input line
    esac
    if [[ $cur == *❯* ]] && [ "$cur" = "$prev" ]; then
      return 0
    fi
    prev=$cur
    sleep 0.3
  done
  return 1
}

is_peon_session() {
  local session=$1
  [ "$(tmux show-options -qv -t "$session" @peon_code 2>/dev/null || true)" = 1 ]
}

cmd_dismiss() {
  local session
  session=$(session_name "${1:-}")
  if ! tmux has-session -t "=$session" 2>/dev/null; then
    echo "peon-code: no session $session"
    exit 0
  fi
  is_peon_session "$session" || die "session $session was not created by peon-code"
  echo "peon-code: killing session $session"
  tmux kill-session -t "=$session"
}

cmd_msg() {
  local target=${1:-} text=${2:-} session panes id name buffer
  [ -n "$target" ] && [ -n "$text" ] || die "usage: peon-code.sh msg <name|all> 'text' [<session>]"
  session=$(session_name "${3:-}")
  tmux has-session -t "=$session" 2>/dev/null || die "no session $session"
  is_peon_session "$session" || die "session $session was not created by peon-code"
  panes=$(list_agent_panes "$session") || true
  [ -n "$panes" ] || die "no agent panes in session $session"
  local ids=()
  while read -r id name; do
    if [ "$target" = all ] || [ "$target" = "$name" ]; then
      ids+=("$id")
    fi
  done <<<"$panes"
  if [ ${#ids[@]} -eq 0 ]; then
    echo "peon-code: no pane named $target in session $session. Agent panes found:" >&2
    while read -r id name; do
      echo "  $name $id" >&2
    done <<<"$panes"
    exit 1
  fi
  buffer="peon-msg-$$"
  printf '%s' "[from user] $text" | tmux load-buffer -b "$buffer" -
  for id in "${ids[@]}"; do
    tmux paste-buffer -b "$buffer" -t "$id" -p
  done
  sleep 1
  for id in "${ids[@]}"; do
    tmux send-keys -t "$id" Enter
  done
  tmux delete-buffer -b "$buffer"
  echo "peon-code: sent to ${#ids[@]} pane(s) in session $session"
}

# Every agent pane on the server, so a session can be found without
# remembering the directory it was launched from. A pane back at a shell
# is reported as gone: its agent exited.
cmd_list() {
  local out rows="" session id cmd name
  # Tab-separated: a session name can hold spaces.
  out=$(tmux list-panes -a -F $'#{session_name}\t#{pane_id}\t#{pane_current_command}\t#{@peon_name}' 2>/dev/null) || out=""
  while IFS=$'\t' read -r session id cmd name; do
    [ -n "$name" ] || continue
    # An agent CLI renames its process, so the name itself says little;
    # what the user needs is whether the pane is back at a shell.
    case $cmd in
      sh|bash|zsh|fish|dash|ksh) cmd="gone ($cmd)" ;;
      *) cmd=running ;;
    esac
    rows+=$(printf '%-16s %-10s %-6s %s' "$session" "$name" "$id" "$cmd")$'\n'
  done <<<"$out"
  [ -n "$rows" ] || { echo "peon-code: no agent panes"; return; }
  printf '%-16s %-10s %-6s %s\n' SESSION AGENT PANE STATUS
  printf '%s' "$rows" | sort
}

goto_session() {
  local session=$1
  # No TTY means a headless caller: build the session, print how to reach it.
  if [ ! -t 0 ]; then
    echo "peon-code: session $session is ready. Attach with: tmux attach -t $session"
    exit 0
  fi
  if [ -n "${TMUX:-}" ]; then
    exec tmux switch-client -t "=$session"
  fi
  exec tmux attach -t "=$session"
}

create_agent_session() {
  local session=$1 count=$2 main=$3 i pane_id
  # First agent is the new-session window; the rest are split off it.
  # Retile after each split so large teams do not hit "pane too small".
  tmux new-session -d -s "$session" -n agents -c "$PWD"
  tmux set-option -t "$session" @peon_code 1
  # Session-scoped, so the terminal tab caption is set only here.
  tmux set -t "$session" set-titles on
  tmux set -t "$session" set-titles-string '#S : #{b:pane_current_path}'
  for ((i = 1; i < count; i++)); do
    if ! tmux split-window -t "$session":agents -c "$PWD"; then
      tmux kill-session -t "=$session"
      die "could not make pane $((i + 1)) of $count; killed session $session"
    fi
    tmux select-layout -t "$session":agents tiled >/dev/null || true
  done

  # Stable pane IDs survive pane moves and layout changes, unlike indices.
  PANE_IDS=()
  while read -r pane_id; do
    PANE_IDS+=("$pane_id")
  done < <(tmux list-panes -t "$session":agents -F '#{pane_id}')

  # A failed split leaves a half-built session; drop the one this run made.
  if [ ${#PANE_IDS[@]} -ne "$count" ]; then
    tmux kill-session -t "=$session"
    die "made ${#PANE_IDS[@]} panes for $count agents; killed session $session"
  fi

  # The main agent's pane takes the whole left side, the others stack to its
  # right. Swapped into the first position first, since main-vertical makes
  # that pane the main one. PANE_IDS is left alone: a pane id follows its
  # pane. A layout call tmux rejects leaves the tiled arrangement in place.
  [ "$main" -eq 0 ] || tmux swap-pane -d -s "${PANE_IDS[$main]}" -t "${PANE_IDS[0]}"
  tmux set-option -w -t "$session":agents main-pane-width 60% || true
  tmux select-layout -t "$session":agents main-vertical >/dev/null || true
}
