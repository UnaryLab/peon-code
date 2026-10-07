# shellcheck shell=bash

# Paste text into agent panes, one at a time, with the Enter after each paste
# held back until that pane's box shows the message. A pane in copy mode, on a
# dialog or a menu, or whose box holds typed text is skipped before the paste,
# so the typed text stays its own. A pane that is skipped, refuses the paste,
# or never shows it is reported and the rest still get theirs; the count is of panes that took an Enter. A run where any pane
# took no message ends nonzero.
cmd_msg() {
  local target=${1:-} text=${2:-} session panes id name pair sent=0 unsent=0
  [ -n "$target" ] && [ -n "$text" ] || die "usage: peon-code.sh msg <name|all> 'text' [<session>]"
  session=$(session_name "${3:-}")
  tmux has-session -t "=$session" 2>/dev/null || die "no session $session"
  is_peon_session "$session" || die "session $session was not created by peon-code"
  panes=$(list_agent_panes "$session") || true
  [ -n "$panes" ] || die "no agent panes in session $session"
  local pairs=()
  while read -r id name; do
    if [ "$target" = all ] || [ "$target" = "$name" ]; then
      pairs+=("$id $name")
    fi
  done <<<"$panes"
  if [ ${#pairs[@]} -eq 0 ]; then
    echo "peon-code: no pane named $target in session $session. Agent panes found:" >&2
    while read -r id name; do
      echo "  $name $id" >&2
    done <<<"$panes"
    exit 1
  fi
  # Panes are taken one after another: a pane whose box never shows the paste
  # holds the run for about 3 seconds before the next pane is tried.
  for pair in "${pairs[@]}"; do
    id=${pair%% *}
    name=${pair#* }
    pane_box_ready "$id" || {
      case $? in
        1) echo "peon-code: no message sent to $name $id: it is in copy mode" >&2 ;;
        2) echo "peon-code: no message sent to $name $id: it draws no prompt marker peon-code knows, so peon-code cannot message it" >&2 ;;
        3) echo "peon-code: no message sent to $name $id: it is on a dialog or a menu" >&2 ;;
        *) echo "peon-code: no message sent to $name $id: its input box holds typed text" >&2 ;;
      esac
      unsent=$((unsent + 1)); continue
    }
    printf '%s' "[from user] $text" | paste_to_pane "$id" || case $? in
      1) echo "peon-code: no message sent to $name $id: tmux refused the paste" >&2
         unsent=$((unsent + 1)); continue ;;
      2) echo "peon-code: no Enter sent to $name $id: the message is in its box for you to submit" >&2
         unsent=$((unsent + 1)); continue ;;
      3|75) echo "peon-code: no message sent to $name $id: input or another delivery is busy" >&2
         unsent=$((unsent + 1)); continue ;;
      *) echo "peon-code: no message sent to $name $id: unexpected status from the paste" >&2
         unsent=$((unsent + 1)); continue ;;
    esac
    sent=$((sent + 1))
  done
  echo "peon-code: sent to $sent pane(s) in session $session"
  [ "$sent" -gt 0 ] || die "no message sent in session $session"
  [ "$unsent" -eq 0 ] || die "$unsent message(s) were not delivered in session $session"
}

# Send a context slash command (/compact, /clear) to agent panes, then paste
# each pane's brief back once the command has finished, since both commands
# drop the standing instructions. The slash command is pasted on its own: any
# text before it stops the CLI from reading it as a command. A pane whose
# input box cannot be read or holds typed text is skipped, and the rest still
# get the command. Enter follows only once the box holds the command alone, so
# a dialog or an autocomplete list that opened after the paste does not take
# the Enter as its answer.
cmd_compact() { slash_then_rebrief /compact "$@"; }
cmd_clear() { slash_then_rebrief /clear "$@"; }

slash_then_rebrief() {
  local slash=$1 target=${2:-all} session panes id name pair box i submitted sent=0
  local pairs=() done_panes=()
  session=$(session_name "${3:-}")
  tmux has-session -t "=$session" 2>/dev/null || die "no session $session"
  is_peon_session "$session" || die "session $session was not created by peon-code"
  panes=$(list_agent_panes "$session") || true
  [ -n "$panes" ] || die "no agent panes in session $session"
  while read -r id name; do
    if [ "$target" = all ] || [ "$target" = "$name" ]; then
      pairs+=("$id $name")
    fi
  done <<<"$panes"
  if [ ${#pairs[@]} -eq 0 ]; then
    echo "peon-code: no pane named $target in session $session. Agent panes found:" >&2
    while read -r id name; do
      echo "  $name $id" >&2
    done <<<"$panes"
    exit 1
  fi
  # A pane taking its own $slash cannot process it: that pane's agent is
  # mid-turn on this very command, so a paste to it queues up and fires
  # late, out of order with the rebrief that follows, and the other target
  # panes would end up cleared and rebriefed while the caller keeps its old
  # context. If the calling pane is among the targets, send to none of them.
  if [ -n "${TMUX_PANE:-}" ]; then
    for pair in "${pairs[@]}"; do
      if [ "${pair%% *}" = "$TMUX_PANE" ]; then
        echo "peon-code: not sending $slash: the calling pane is a target; run this command from a shell or another pane instead" >&2
        return 0
      fi
    done
  fi
  for pair in "${pairs[@]}"; do
    id=${pair%% *}
    name=${pair#* }
    submitted=0
    if with_pane_delivery "$id" slash_locked "$id" "$slash"; then submitted=1; fi
    if [ "$submitted" -eq 1 ]; then
      sent=$((sent + 1))
      done_panes+=("$pair")
    else
      echo "peon-code: no Enter sent to $id: it holds something other than $slash, which is in its box for the user to submit" >&2
    fi
  done
  [ "$sent" -gt 0 ] || die "no pane took $slash in session $session"
  echo "peon-code: sent $slash to $sent pane(s) in session $session"
  # The command runs for as long as the context takes, well past the settle
  # wait's default ceiling, so the wait is given 120s here. A pane still
  # drawing after that keeps its brief unsent rather than taking a paste
  # into whatever is on screen.
  for pair in ${done_panes[@]+"${done_panes[@]}"}; do
    id=${pair%% *}
    name=${pair#* }
    if ! wait_pane_settled "$id" 400; then
      echo "peon-code: no brief sent to $name $id: it is still busy after $slash" >&2
      continue
    fi
    rebrief_pane "$id" "$name" || case $? in
      2) echo "peon-code: no brief sent to $name $id: tmux refused the paste" >&2 ;;
      3) echo "peon-code: no brief sent to $name $id: its input box holds typed text, or it is on a dialog or a menu" >&2 ;;
      4) echo "peon-code: no Enter sent to $name $id: the brief is in its box for the user to submit" >&2 ;;
    esac
  done
}

# Send one agent's message to another agent's pane. A message of - is read
# from stdin, which keeps quotes in it off the sender's command line. One run
# makes the box check and the paste back to back, and Enter follows only once
# the box shows the message, as box_holds_message decides; a box holding
# anything else keeps both the message and whatever the user typed.
cmd_send() {
  with_pane_delivery "${1:-}" send_locked "$@"
}

cmd_key() {
  local pane=${1:-} name=${2:-}
  if [ $# -ne 2 ] || [ -z "$pane" ]; then
    die "usage: peon-code.sh key <pane-id> <name>"
  fi
  case $name in
    Tab|Up|Down|Enter|Escape|1|2|3|4|5|6|7|8|9) ;;
    *) echo "peon-code: allowed keys: Tab, Up, Down, Enter, Escape, 1..9" >&2; return 2 ;;
  esac
  with_pane_delivery "$pane" key_locked "$@"
}

key_locked() {
  local pane=$1 name=$2 capture
  pane_identity_matches "$pane" || die "no key sent: agent changed"
  case $(tmux display -pt "$pane" '#{pane_current_command}' 2>/dev/null || true) in
    "") die "no pane $pane" ;;
    sh|bash|zsh|fish|dash|ksh) die "pane $pane is back at a shell; its agent is gone" ;;
  esac
  [ -n "$(tmux show-options -pqv -t "$pane" @peon_name 2>/dev/null || true)" ] ||
    die "pane $pane is not a peon-code agent pane"
  if [ "$name" = Enter ]; then
    capture=$(tmux capture-pane -pt "$pane" 2>/dev/null) || die "cannot read pane $pane"
    pane_has_menu "$capture" || die "no Enter sent: pane $pane is not on a menu"
  fi
  pane_takes_keys "$pane" || die "no key sent: pane $pane is in copy mode"
  pane_identity_matches "$pane" || die "no key sent: agent changed"
  tmux send-keys -t "$pane" "$name" || die "no key sent: tmux refused the key for $pane"
}

send_locked() {
  local pane=${1:-} text=${2:-} want box i rc reason
  [ -n "$pane" ] && [ -n "$text" ] || die "usage: peon-code.sh send <pane-id> 'text'|-"
  pane_identity_matches "$pane" || die "no message sent: agent changed"
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
  # Copy mode, a dialog or a menu, and a box holding typed text all clear on
  # their own, so these checks retry: 10 tries, one second apart. A pane
  # drawing no prompt marker never clears, so that one dies at once.
  reason=""
  for ((i = 0; i < 10; i++)); do
    rc=0
    pane_box_ready "$pane" || rc=$?
    case $rc in
      0) reason="" ;;
      1) reason="pane $pane is in copy mode" ;;
      2) die "pane $pane draws no prompt marker peon-code knows, so peon-code cannot message it" ;;
      3) reason="pane $pane is on a dialog or a menu" ;;
      *) reason="target box busy" ;;
    esac
    [ -n "$reason" ] || break
    if [ "$i" -lt 9 ]; then sleep 1; fi
  done
  [ -z "$reason" ] || die "$reason after 10 tries, giving up"
  want=$(printf '%s' "$text" | plain_text)
  printf '%s' "$text" | paste_only "$pane" ||
    die "no message sent: tmux refused the paste"
  for ((i = 0; i < 10; i++)); do
    sleep 0.2
    box=$(pane_box_text "$pane") || box=""
    if box_holds_message "$box" "$want"; then
      pane_takes_keys "$pane" ||
        die "no Enter sent: pane $pane went into copy mode, and the message is in its box for the user to submit"
      pane_identity_matches "$pane" || die "no Enter sent: agent changed"
      tmux send-keys -t "$pane" Enter || die "no Enter sent: tmux refused submission to $pane"
      echo "peon-code: sent to $pane"
      return 0
    fi
  done
  die "no Enter sent: pane $pane holds something other than the message, which is still in its box for the user to sort out"
}

# Paste one pane's launch brief again. The brief file path is stored on each
# pane as the @peon_brief option at launch; a pane without one is left alone
# and reported, which returns 1, as does a pane drawing no prompt marker. A
# paste tmux refused returns 2. A pane whose input box holds typed text, or
# that sits on a dialog or a menu, takes nothing and returns 3, so the box
# keeps what the user typed and no Enter answers the dialog. A brief the box
# never showed, so no Enter followed it, returns 4.
rebrief_pane() {
  with_pane_delivery "$1" rebrief_locked "$@"
}

rebrief_locked() {
  local id=$1 name=$2 brief box
  brief=$(tmux show-options -pqv -t "$id" @peon_brief 2>/dev/null) || brief=""
  if [ -z "$brief" ] || [ ! -f "$brief" ]; then
    echo "peon-code: no stored brief for $name $id: pane from an older launch, or its brief file is gone" >&2
    return 1
  fi
  box=$(pane_box_text "$id") || case $? in
    2) echo "peon-code: no brief sent to $name $id: it draws no prompt marker peon-code knows" >&2; return 1 ;;
    *) return 3 ;;
  esac
  [ -z "$box" ] || return 3
  paste_to_pane "$id" <"$brief" || case $? in
    2) return 4 ;;
    3|75) return 3 ;;
    *) return 2 ;;
  esac
  return 0
}

# Paste the launch brief again into every named pane, so an agent that
# compacted its conversation gets its standing instructions back.
cmd_rebrief() {
  local target=${1:-} session panes id name found=0 sent=0 unsent=0
  [ -n "$target" ] || die "usage: peon-code.sh rebrief <name|all> [<session>]"
  session=$(session_name "${2:-}")
  tmux has-session -t "=$session" 2>/dev/null || die "no session $session"
  is_peon_session "$session" || die "session $session was not created by peon-code"
  panes=$(list_agent_panes "$session") || true
  [ -n "$panes" ] || die "no agent panes in session $session"
  while read -r id name; do
    [ "$target" = all ] || [ "$target" = "$name" ] || continue
    found=1
    rebrief_pane "$id" "$name" || case $? in
      2) echo "peon-code: no brief sent to $name $id: tmux refused the paste" >&2
         unsent=$((unsent + 1)); continue ;;
      3) echo "peon-code: no brief sent to $name $id: its input box holds typed text, or it is on a dialog or a menu" >&2
         continue ;;
      4) echo "peon-code: no Enter sent to $name $id: the brief is in its box for the user to submit" >&2
         unsent=$((unsent + 1)); continue ;;
      *) continue ;;
    esac
    sent=$((sent + 1))
  done <<<"$panes"
  [ "$found" -eq 1 ] || die "no pane named $target in session $session"
  [ "$sent" -gt 0 ] || die "no brief sent in session $session"
  echo "peon-code: rebriefed $sent pane(s) in session $session"
  [ "$unsent" -eq 0 ] || die "$unsent brief(s) were not delivered in session $session"
}

slash_locked() {
  local id=$1 slash=$2 box i submitted
  if ! pane_takes_keys "$id"; then
    echo "peon-code: skipped $id: it is in copy mode" >&2
    return 1
  fi
  box=$(pane_box_text "$id") || case $? in
    2) echo "peon-code: skipped $id: it draws no prompt marker peon-code knows" >&2; return 1 ;;
    *) echo "peon-code: skipped $id: it is on a dialog or a menu" >&2; return 1 ;;
  esac
  if [ -n "$box" ]; then
    echo "peon-code: skipped $id: its input box holds typed text" >&2
    return 1
  fi
  if ! printf '%s' "$slash" | paste_only "$id"; then
    echo "peon-code: skipped $id: tmux refused the paste" >&2
    return 1
  fi
  submitted=0
  for ((i = 0; i < 10; i++)); do
    sleep 0.2
    box=$(pane_box_text "$id") || box=""
    [ "$box" = "$slash" ] || continue
    pane_takes_keys "$id" || break
    tmux send-keys -t "$id" Enter || return 1
    submitted=1
    break
  done
  [ "$submitted" -eq 1 ]
}
