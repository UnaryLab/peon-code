# shellcheck shell=bash

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

cmd_detach() {
  local session
  session=$(session_name "${1:-}")
  tmux has-session -t "=$session" 2>/dev/null || die "no session $session"
  is_peon_session "$session" || die "session $session was not created by peon-code"
  tmux detach-client -s "=$session"
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
  enable_mouse_ui "$session"
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
  tmux set-option -t "$session" @peon_project_dir "$PWD"
  # Session-scoped, so the terminal tab caption is set only here.
  tmux set -t "$session" set-titles on
  tmux set -t "$session" set-titles-string '#S : #{b:pane_current_path}'
  # Agent CLIs rewrite the pane title, so the border reads the @peon_name option.
  tmux set -w -t "$session":agents pane-border-status top
  tmux set -w -t "$session":agents pane-border-format ' #{pane_index}: #{?#{@peon_name},#{@peon_name},#{pane_title}} '
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
