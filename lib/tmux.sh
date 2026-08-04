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

# Paste stdin into a pane. Bracketed paste keeps a multi-line block in the
# input line instead of submitting it early; long lines sent with send-keys
# are cut at the tty line limit. Every control byte but tab and newline is
# dropped first: tmux does not escape a bracketed-paste terminator inside the
# text, so text carrying one would end the paste early and leave the rest of
# itself to the receiving app as live keystrokes.
paste_only() {
  local pane=$1 buffer="peon-code-$$-${1#%}"
  LC_ALL=C tr -d '\000-\010\013-\037\177' | tmux load-buffer -b "$buffer" -
  tmux paste-buffer -b "$buffer" -dpt "$pane"
}

# Paste stdin into a pane, then press Enter as a separate call.
paste_to_pane() {
  paste_only "$1"
  sleep 1
  tmux send-keys -t "$1" Enter
}

# Printable ASCII only, runs of blanks squeezed to one space, ends trimmed:
# the shape a captured box and a message are both reduced to before they are
# compared, so the box's wrapping and padding do not count as a difference.
plain_text() {
  local s
  # LC_ALL=C: a capture holds the box drawing of the pane, and tr in a UTF-8
  # locale rejects those bytes instead of dropping them.
  s=$(LC_ALL=C tr -cd '\11\12\40-\176' | LC_ALL=C tr -s '\11\12\40' '\40')
  s=${s# }
  s=${s% }
  printf '%s' "$s"
}

# A capture holding a menu: the marker is drawn on the menu's selected row
# with the cursor right after it, so the input box measures empty while the
# pane is waiting on an answer.
pane_has_menu() {
  case $1 in
    *"Enter to confirm"*|*"❯ "[0-9]"."*) return 0 ;;
  esac
  return 1
}

# A pane in copy mode routes keys through the copy-mode key table, so a paste
# lands in the pane but the Enter after it never reaches the app.
pane_takes_keys() {
  [ "$(tmux display -pt "$1" '#{pane_in_mode}' 2>/dev/null || echo 1)" = 0 ]
}

# What a pane's input box holds: everything from the prompt marker to the end
# of the cursor's row. Text after the cursor counts too, so a box whose cursor
# was moved back to the start still measures busy. Empty output means an empty
# box. A pane sitting on a menu returns 1; a pane drawing no prompt marker at
# or above the cursor returns 2, which no wait can change.
# ponytail: one column per glyph, so a box holding wide characters measures
# short; count widths here if agents start sending CJK or emoji.
# ponytail: whatever a TUI draws after the cursor on that row (hint text, a
# right border) reads as typed text and holds the send; read the colors of the
# region with capture-pane -e if a TUI that draws one has to be supported.
pane_box_text() {
  local pane=$1 cy cap box
  cy=$(tmux display -pt "$pane" '#{cursor_y}' 2>/dev/null) || return 1
  cap=$(tmux capture-pane -pt "$pane" 2>/dev/null) || return 1
  if pane_has_menu "$cap"; then
    return 1
  fi
  box=$(printf '%s\n' "$cap" | LC_ALL=C awk -v cy="$cy" '
    BEGIN { m = "\342\235\257" }
    { rows[NR] = $0; if (NR <= cy + 1 && index($0, m) > 0) mr = NR }
    END {
      if (!mr) exit 2
      for (r = mr; r <= cy + 1; r++) {
        s = rows[r]
        if (r == mr) s = substr(s, index(s, m) + length(m))
        out = out " " s
      }
      print out
    }') || return 2
  printf '%s' "$box" | plain_text
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
    # Input line drawn and no menu on screen: the pane never showed a picker.
    if ! pane_has_menu "$cur" && [[ $cur == *❯* ]]; then
      return 0
    fi
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
    if pane_has_menu "$cur"; then
      cur=""  # a menu, not the input line
    fi
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
  local target=${1:-} text=${2:-} session panes id name
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
  for id in "${ids[@]}"; do
    printf '%s' "[from user] $text" | paste_only "$id"
  done
  sleep 1
  for id in "${ids[@]}"; do
    tmux send-keys -t "$id" Enter
  done
  echo "peon-code: sent to ${#ids[@]} pane(s) in session $session"
}

# Send one agent's message to another agent's pane. A message of - is read
# from stdin, which keeps quotes in it off the sender's command line. One run
# makes the box check and the paste back to back, and Enter follows only once
# the box holds the message; a box holding anything else keeps both the
# message and whatever the user typed.
cmd_send() {
  local pane=${1:-} text=${2:-} want box i
  [ -n "$pane" ] && [ -n "$text" ] || die "usage: peon-code.sh send <pane-id> 'text'|-"
  if [ "$text" = - ]; then
    text=$(cat)
    [ -n "$text" ] || die "no message on stdin"
  fi
  case $(tmux display -pt "$pane" '#{pane_current_command}' 2>/dev/null || true) in
    "") die "no pane $pane" ;;
    sh|bash|zsh|fish|dash|ksh) die "pane $pane is back at a shell; its agent is gone" ;;
  esac
  # The pane option is set on agent panes at launch: a paste is refused
  # anywhere else, rather than reaching any pane on the tmux server.
  [ -n "$(tmux show-options -pqv -t "$pane" @peon_name 2>/dev/null || true)" ] ||
    die "pane $pane is not a peon-code agent pane"
  pane_takes_keys "$pane" || die "pane $pane is in copy mode, retry later"
  box=$(pane_box_text "$pane") || case $? in
    2) die "pane $pane draws no prompt marker peon-code knows; message it by hand" ;;
    *) die "pane $pane is on a dialog or a menu, retry later" ;;
  esac
  [ -z "$box" ] || die "target box busy, retry later"
  want=$(printf '%s' "$text" | plain_text)
  printf '%s' "$text" | paste_only "$pane"
  for ((i = 0; i < 10; i++)); do
    sleep 0.2
    box=$(pane_box_text "$pane") || box=""
    if [ "$box" = "$want" ]; then
      pane_takes_keys "$pane" ||
        die "no Enter sent: pane $pane went into copy mode, and the message is in its box for the user to submit"
      tmux send-keys -t "$pane" Enter
      echo "peon-code: sent to $pane"
      return 0
    fi
  done
  die "no Enter sent: pane $pane holds something other than the message, which is still in its box for the user to sort out"
}

# Paste a pane's launch brief again, so an agent that compacted its
# conversation gets its standing instructions back. The brief file path
# is stored on each pane as the @peon_brief option at launch.
cmd_rebrief() {
  local target=${1:-} session panes id name brief found=0 sent=0
  [ -n "$target" ] || die "usage: peon-code.sh rebrief <name|all> [<session>]"
  session=$(session_name "${2:-}")
  tmux has-session -t "=$session" 2>/dev/null || die "no session $session"
  is_peon_session "$session" || die "session $session was not created by peon-code"
  panes=$(list_agent_panes "$session") || true
  [ -n "$panes" ] || die "no agent panes in session $session"
  while read -r id name; do
    [ "$target" = all ] || [ "$target" = "$name" ] || continue
    found=1
    brief=$(tmux show-options -pqv -t "$id" @peon_brief 2>/dev/null) || brief=""
    if [ -z "$brief" ] || [ ! -f "$brief" ]; then
      echo "peon-code: no stored brief for $name $id: pane from an older launch, or its brief file is gone" >&2
      continue
    fi
    paste_to_pane "$id" <"$brief"
    sent=$((sent + 1))
  done <<<"$panes"
  [ "$found" -eq 1 ] || die "no pane named $target in session $session"
  [ "$sent" -gt 0 ] || die "no brief sent in session $session"
  echo "peon-code: rebriefed $sent pane(s) in session $session"
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
