# shellcheck shell=bash

cmd_statusline() {
  local input record used resets
  # The sentinel keeps trailing newlines through command substitution.
  input=$(cat; printf '.') || input=""
  input=${input%.}
  record=$(printf '%s' "$input" | tr '\n' ' ' | sed -n 's/.*"seven_day"[[:space:]]*:[[:space:]]*\({[^}]*}\).*/\1/p') || record=""
  used=$(printf '%s' "$record" | sed -n 's/.*"used_percentage"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\(\.[0-9][0-9]*\)\{0,1\}\)[[:space:]]*[,}].*/\1/p') || used=""
  resets=$(printf '%s' "$record" | sed -n 's/.*"resets_at"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\)[[:space:]]*[,}].*/\1/p') || resets=""
  if [ -n "${TMUX_PANE:-}" ] && [ -n "$used" ] && [ -n "$resets" ]; then
    used=$(LC_ALL=C awk -v used="$used" 'BEGIN { printf "%.1f", (used + 0 > 100 ? 100 : used) }') || used=""
    [ -z "$used" ] || tmux set -pt "$TMUX_PANE" @peon_weekly "$used $resets" 2>/dev/null || true
  fi
  [ $# -gt 0 ] || return 0
  sh -c "$1" < <(printf '%s' "$input")
}

# Paste text into agent panes, one at a time, with the Enter after each paste
# held back until that pane's box shows the message. A pane in copy mode, on a
# dialog or a menu, or whose box holds typed text is skipped before the paste,
# so the typed text stays its own. A pane that is skipped, refuses the paste,
# or never confirms submission is reported and the rest still get theirs;
# the count is of confirmed submissions. Any failure ends nonzero.
cmd_msg() {
  local target=${1:-} text=${2:-} session panes id name pair sent=0 unsent=0
  # shellcheck disable=SC2015 # Both required arguments must be present.
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
        5) echo "peon-code: skipped $id: it is in shell mode" >&2 ;;
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
      4) echo "peon-code: Enter sent to $name $id but submission not confirmed" >&2
         unsent=$((unsent + 1)); continue ;;
      *) echo "peon-code: no message sent to $name $id: unexpected status from the paste" >&2
         unsent=$((unsent + 1)); continue ;;
    esac
    sent=$((sent + 1))
  done
  echo "peon-code: sent to $sent pane(s) in session $session"
  [ "$sent" -gt 0 ] || die "no message confirmed in session $session"
  [ "$unsent" -eq 0 ] || die "$unsent message(s) were not confirmed in session $session"
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
  local slash=$1 target=${2:-all} session panes id name pair box i submitted deadline ready sent=0
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
    with_pane_delivery "$id" slash_locked "$id" "$slash" || submitted=$?
    if [ "$submitted" -eq 0 ]; then
      sent=$((sent + 1))
      done_panes+=("$pair")
    elif [ "$submitted" -eq 1 ]; then
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
    deadline=$((SECONDS + 120))
    ready=0
    for ((i = 0; i < 400 && SECONDS < deadline; i++)); do
      if wait_pane_settled "$id" 3 && ! pane_is_busy "$id"; then ready=1; break; fi
    done
    if [ "$ready" -eq 0 ]; then
      tmux set -pt "$id" @peon_rebrief_pending 1
      echo "peon-code: no brief sent to $name $id: it is still busy after $slash" >&2
      continue
    fi
    rebrief_pane "$id" "$name" || case $? in
      2) echo "peon-code: no brief sent to $name $id: tmux refused the paste" >&2 ;;
      3) echo "peon-code: no brief sent to $name $id: its input box holds typed text, or it is on a dialog or a menu" >&2 ;;
      4) echo "peon-code: no Enter sent to $name $id: the brief is in its box for the user to submit" >&2 ;;
      5) echo "peon-code: Enter sent to $name $id but brief submission not confirmed" >&2 ;;
    esac
  done
}

# Send one agent's message to another agent's pane. A message of - is read
# from stdin, which keeps quotes in it off the sender's command line. One run
# makes the box check and the paste back to back, and Enter follows only once
# the box shows the message, as box_holds_message decides. --append includes
# the user's existing text in that check.
cmd_send() {
  local append=0
  if [ "${1:-}" = --append ]; then append=1; shift; fi
  with_pane_delivery "${1:-}" send_locked "${1:-}" "${2:-}" "$append"
}

cmd_explain() {
  local pane=${1:-} text result rc=0
  if [ $# -ne 1 ] || [ -z "$pane" ]; then
    die "usage: peon-code.sh explain <pane-id> < selected-text"
  fi
  text=$(cat)
  case $text in
    *[![:space:]]*) ;;
    *) tmux display-message -t "$pane" 'peon-code: no selected text'; return 1 ;;
  esac
  result=$(cmd_send "$pane" $'Explain what the following text means in this conversation:\n\n'"$text" 2>&1) || rc=$?
  printf '%s\n' "$result"
  tmux display-message -t "$pane" -- "${result//#/##}"
  return "$rc"
}

cmd_key() {
  local submit=0
  if [ "${1:-}" = --submit ]; then submit=1; shift; fi
  local pane=${1:-} name=${2:-}
  if [ $# -ne 2 ] || [ -z "$pane" ]; then
    die "usage: peon-code.sh key [--submit] <pane-id> <name>"
  fi
  case $name in
    Tab|Up|Down|Left|Right|Enter|Escape|BSpace|C-c) ;;
    *) echo "peon-code: allowed keys: Tab, Up, Down, Left, Right, Enter, Escape, BSpace, C-c" >&2; return 2 ;;
  esac
  with_pane_delivery "$pane" key_locked "$pane" "$name" "$submit"
}

key_locked() {
  local pane=$1 name=$2 submit=${3:-0} capture cy box rc=0
  pane_identity_matches "$pane" || die "no key sent: agent changed"
  case $(tmux display -pt "$pane" '#{pane_current_command}' 2>/dev/null || true) in
    "") die "no pane $pane" ;;
    sh|bash|zsh|fish|dash|ksh) die "pane $pane is back at a shell; its agent is gone" ;;
  esac
  [ -n "$(tmux show-options -pqv -t "$pane" @peon_name 2>/dev/null || true)" ] ||
    die "pane $pane is not a peon-code agent pane"
  if [ "$name" = Enter ]; then
    cy=$(tmux display -pt "$pane" '#{cursor_y}' 2>/dev/null) || die "cannot read cursor for pane $pane"
    capture=$(tmux capture-pane -pt "$pane" 2>/dev/null && printf '.') || die "cannot read pane $pane"
    capture=${capture%.}
    pane_has_menu "$capture" "$cy" || rc=$?
    [ "$rc" -ne 2 ] || die "no $name sent: cannot read input box in pane $pane"
    if [ "$rc" -ne 0 ]; then
      [ "$submit" = 1 ] || die "no Enter sent: pane $pane is not on a menu"
      box=$(pane_box_text "$pane") || [ "$?" -eq 5 ] || die "no Enter sent: cannot read input box in pane $pane"
      [ -n "$box" ] || die "no Enter sent: nothing to submit"
    fi
  fi
  pane_takes_keys "$pane" || die "no key sent: pane $pane is in copy mode"
  pane_identity_matches "$pane" || die "no key sent: agent changed"
  tmux send-keys -t "$pane" "$name" || die "no key sent: tmux refused the key for $pane"
}

send_locked() {
  local pane=${1:-} text=${2:-} append=${3:-0} want box i rc reason cursor end_cursor last key login=0 previous=""
  # shellcheck disable=SC2015 # Both required arguments must be present.
  [ -n "$pane" ] && [ -n "$text" ] || die "usage: peon-code.sh send [--append] <pane-id> 'text'|-"
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
      4) if [ "$append" = 1 ]; then reason=""; else reason="target box busy"; fi ;;
      5) die "skipped $pane: it is in shell mode" ;;
      *) reason="target box busy" ;;
    esac
    [ -n "$reason" ] || break
    if [ "$i" -lt 9 ]; then sleep 1; fi
  done
  if [ -n "$reason" ]; then
    [ "$rc" -ne 4 ] || die "$reason after 10 tries, giving up: its input box holds typed text"
    die "$reason after 10 tries, giving up"
  fi
  want=$(printf '%s' "$text" | plain_text)
  if [ -n "${CLI_LOGIN_PROMPT:-}" ] &&
    tmux capture-pane -pt "$pane" | login_box_text "$(tmux display -pt "$pane" '#{cursor_y}')" >/dev/null; then
    login=1
    append=0
  fi
  if [ "$append" = 1 ]; then
    box=$(pane_box_text "$pane") || die "no message sent: target box changed"
    if [ -n "$box" ]; then
      # Read the cell before the end cursor: normalized box text drops whitespace.
      for key in End Left End; do
        pane_takes_keys "$pane" || die "no message sent: pane $pane is in copy mode"
        pane_identity_matches "$pane" || die "no message sent: agent changed"
        tmux send-keys -t "$pane" "$key" || die "no message sent: tmux refused cursor movement"
        for ((i = 0; i < 10; i++)); do
          sleep 0.2
          cursor=$(tmux display -pt "$pane" '#{cursor_x} #{cursor_y}') || die "no message sent: cannot read cursor"
          if [ "$key" = Left ]; then
            [ "$cursor" != "$end_cursor" ] || continue
          elif [ -n "${end_cursor:-}" ]; then
            [ "$cursor" = "$end_cursor" ] || continue
          fi
          break
        done
        [ "$i" -lt 10 ] || die "no message sent: cursor did not move"
        if [ "$key" = Left ]; then
          last=$(tmux display -pt "$pane" '#{cursor_character}') || die "no message sent: cannot read cursor character"
        else
          end_cursor=$cursor
        fi
      done
      case $last in
        [[:space:]]|$'\302\240') ;;
        *) text=" $text" ;;
      esac
      want=$(printf '%s %s' "$box" "$text" | plain_text)
      pane_takes_keys "$pane" || die "no message sent: pane $pane is in copy mode"
      pane_identity_matches "$pane" || die "no message sent: agent changed"
      pane_box_text "$pane" >/dev/null || die "no message sent: target box changed"
    fi
  fi
  printf '%s' "$text" | paste_only "$pane" ||
    die "no message sent: tmux refused the paste"
  for ((i = 0; i < 25; i++)); do
    sleep 0.2
    box=$(pane_box_text "$pane") || box=""
    if [ "$box" != "$previous" ]; then previous=$box; continue; fi
    if box_holds_message "$box" "$want" "$login"; then
      pane_takes_keys "$pane" ||
        die "no Enter sent: pane $pane went into copy mode, and the message is in its box for the user to submit"
      pane_identity_matches "$pane" || die "no Enter sent: agent changed"
      rc=0
      submit_paste "$pane" "$want" "$login" || rc=$?
      case $rc in
        0) echo "peon-code: sent to $pane"; return 0 ;;
        2) die "Enter sent to $pane but submission not confirmed: pane went into copy mode" ;;
        3) die "Enter sent to $pane but submission not confirmed: agent changed" ;;
        4) die "no Enter sent: tmux refused submission to $pane" ;;
        5) die "Enter sent to $pane but submission not confirmed: tmux refused a retry" ;;
        *) die "Enter sent to $pane but submission not confirmed: input box did not read empty" ;;
      esac
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
# never showed, so no Enter followed it, returns 4. An Enter whose submission
# cannot be confirmed returns 5.
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
  pane_identity_matches "$id" || return 1
  ! pane_is_busy "$id" || return 3
  box=$(pane_box_text "$id") || case $? in
    2) echo "peon-code: no brief sent to $name $id: it draws no prompt marker peon-code knows" >&2; return 1 ;;
    5) echo "peon-code: skipped $id: it is in shell mode" >&2; return 1 ;;
    *) return 3 ;;
  esac
  [ -z "$box" ] || return 3
  paste_to_pane "$id" <"$brief" || case $? in
    2) return 4 ;;
    3|75) return 3 ;;
    4) return 5 ;;
    *) return 2 ;;
  esac
  tmux set -pu -t "$id" @peon_rebrief_pending
  return 0
}

# Paste the launch brief again into every named pane, so an agent that
# compacted its conversation gets its standing instructions back.
# The internal pane list skips new agents, which already have a brief.
cmd_rebrief() {
  rebrief_agents "${1:-}" "${2:-}"
}

rebrief_agents() {
  local target=${1:-} only=${3:-} session panes id name found=0 sent=0 unsent=0
  [ -n "$target" ] || die "usage: peon-code.sh rebrief <name|all> [<session>]"
  session=$(session_name "${2:-}")
  tmux has-session -t "=$session" 2>/dev/null || die "no session $session"
  is_peon_session "$session" || die "session $session was not created by peon-code"
  panes=$(list_agent_panes "$session") || true
  while read -r id name; do
    [ -n "$id" ] || continue
    [ "$target" = all ] || [ "$target" = "$name" ] || continue
    if [ -n "$only" ]; then
      case " $only " in *" $id "*) ;; *) continue ;; esac
    fi
    found=1
    if [ "$id" = "${TMUX_PANE:-}" ]; then
      echo "peon-code: run peon-code.sh rebrief $name $session when it is free" >&2
      continue
    fi
    rebrief_pane "$id" "$name" || case $? in
      2) echo "peon-code: no brief sent to $name $id: tmux refused the paste" >&2
         unsent=$((unsent + 1)); continue ;;
      3) echo "peon-code: no brief sent to $name $id: its input box holds typed text, or it is on a dialog or a menu, or it is busy with a turn" >&2
         echo "peon-code: run peon-code.sh rebrief $name $session when it is free" >&2
         continue ;;
      4) echo "peon-code: no Enter sent to $name $id: the brief is in its box for the user to submit" >&2
         unsent=$((unsent + 1)); continue ;;
      5) echo "peon-code: Enter sent to $name $id but brief submission not confirmed" >&2
         unsent=$((unsent + 1)); continue ;;
      *) continue ;;
    esac
    sent=$((sent + 1))
  done <<<"$panes"
  if [ "$found" -ne 1 ]; then
    if tmux list-panes -s -t "=$session" -F '#{@peon_name}' | grep -Fxq -- "$target"; then
      die "agent $target is at a shell; its brief is pasted when it restarts"
    fi
    die "no pane named $target in session $session"
  fi
  [ "$sent" -gt 0 ] || die "no brief confirmed in session $session"
  echo "peon-code: rebriefed $sent pane(s) in session $session"
  [ "$unsent" -eq 0 ] || die "$unsent brief(s) were not confirmed in session $session"
}

swap_check() (
  local probe=$1 command=$2 dir pid="" ticks=0 status=0 target="" detail timed_out=0
  local runner=()
  dir=$(mktemp -d "${TMPDIR:-/tmp}/peon-code-check.XXXXXX") || die "could not prepare the CLI check"
  swap_check_stop() {
    [ -n "$pid" ] || return 0
    target=${target:-$pid}
    [ ${#runner[@]} -gt 0 ] || pkill -TERM -P "$pid" 2>/dev/null || true
    kill -TERM -- "$target" 2>/dev/null || true
    ticks=0
    while kill -0 -- "$target" 2>/dev/null && [ "$ticks" -lt 10 ]; do
      sleep 0.1
      ticks=$((ticks + 1))
    done
    if kill -0 -- "$target" 2>/dev/null; then
      [ ${#runner[@]} -gt 0 ] || pkill -KILL -P "$pid" 2>/dev/null || true
      kill -KILL -- "$target" 2>/dev/null || true
    fi
  }
  swap_check_cleanup() {
    trap '' INT TERM
    if [ -n "$pid" ] && kill -0 -- "${target:-$pid}" 2>/dev/null; then swap_check_stop; fi
    [ -z "$pid" ] || wait "$pid" 2>/dev/null || true
    [ -z "${SWAP_CHECK_PID_FILE:-}" ] || rm -f "$SWAP_CHECK_PID_FILE"
    rm -f "$dir/out" "$dir/err"
    rmdir "$dir"
  }
  trap swap_check_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if [ -n "${SWAP_CHECK_PID_FILE:-}" ]; then
    printf '%s\n' "$(exec sh -c 'echo "$PPID"')" >"$SWAP_CHECK_PID_FILE"
  fi
  if command -v setsid >/dev/null 2>&1; then
    runner=(setsid)
    if command -v systemd-run >/dev/null 2>&1 &&
      systemd-run --user --scope -q -p OOMPolicy=continue -- true >/dev/null 2>&1; then
      runner+=(systemd-run --user --scope -q -p OOMPolicy=continue --)
    fi
  fi
  ${runner[@]+"${runner[@]}"} bash -c "$probe" </dev/null >"$dir/out" 2>"$dir/err" &
  pid=$!
  target=$pid
  [ ${#runner[@]} -eq 0 ] || target=-$pid
  while kill -0 "$pid" 2>/dev/null && [ "$ticks" -lt 600 ]; do
    sleep 0.1
    ticks=$((ticks + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    status=124
    timed_out=1
    swap_check_stop
  fi
  if [ "$status" -eq 0 ]; then wait "$pid" 2>/dev/null || status=$?
  else wait "$pid" 2>/dev/null || true; fi
  detail=$(tail -n 1 "$dir/err")
  if [ "$status" -ne 0 ]; then
    if [ -z "$detail" ]; then
      if [ "$timed_out" -eq 1 ]; then detail="timed out after 60 seconds"
      else detail="exit status $status"; fi
    fi
    die "$command failed its check: $detail"
  fi
)

# Provider launch hooks read the pane's settings through Bash's dynamic scope.
# shellcheck disable=SC2034
swap_run() {
  local mode=$1 expected=${2:-} identity log
  shift 2
  local target=${1:-} command=${2:-} session panes id name current old_command old_bin brief main restart quit project_dir
  local BIN ARGS Q LAUNCH MAIN NORMAL_SETTINGS DENY_SETTINGS temp fresh=0 wait_count sender probe
  local physical_dir i=0 NAMES=() project_dirs=()
  [ $# -eq 2 ] || [ $# -eq 3 ] || die "usage: peon-code.sh swap <name> '<command>' [<session>]"
  [ -n "$target" ] || die "swap needs an agent name"
  case $command in
    ''|[[:space:]]*|-*|*$'\n'*|*$'\r'*) die "swap needs a command with a CLI binary first" ;;
  esac
  BIN=${command%% *}
  [[ $BIN =~ ^[A-Za-z0-9_./-]+$ ]] || die "swap needs a command with a CLI binary first"
  bash -n <<<"$command" || die "swap command has invalid shell syntax"
  ARGS=""
  [ "$command" = "$BIN" ] || ARGS=" ${command#* }"
  session=$(session_name "${3:-}")
  tmux has-session -t "=$session" 2>/dev/null || die "no session $session"
  is_peon_session "$session" || die "session $session was not created by peon-code"
  panes=$(tmux list-panes -s -t "=$session" -F '#{pane_id} #{@peon_name}') || die "cannot list panes in session $session"
  id=""
  while read -r current name; do
    [ "$name" = "$target" ] || continue
    id=$current
    break
  done <<<"$panes"
  [ -n "$id" ] || die "no pane named $target in session $session"
  [ "$id" != "${TMUX_PANE:-}" ] || die "cannot swap the calling pane; run from a shell or another pane"
  pane_identity_matches "$id" || die "no swap: agent changed"
  [ -z "$expected" ] || [ "$id" = "$expected" ] || die "no swap: agent changed"
  identity=$(tmux display-message -p -t "$id" '#{pid}:#{session_id}:#{pane_pid}') || die "cannot read pane $id"
  current=$(tmux display -pt "$id" '#{pane_current_command}') || die "cannot read pane $id"
  case $current in
    ''|sh|bash|zsh|fish|dash|ksh|systemd-run) die "$target is at a shell; nothing to swap, launch it instead" ;;
  esac
  project_dir=$(tmux show-options -pqv -t "$id" @peon_project_dir 2>/dev/null) || project_dir=""
  [ -n "$project_dir" ] || project_dir=$(tmux display -pt "$id" '#{pane_current_path}') || project_dir=""
  [ -d "$project_dir" ] && [ -r "$project_dir" ] && [ -x "$project_dir" ] ||
    die "$target has no accessible project directory; launch it again"
  (cd -- "$project_dir" && command -v "$BIN" >/dev/null 2>&1) || die "$BIN is not on PATH"
  old_command=$(tmux show-options -pqv -t "$id" @peon_cmd) || old_command=""
  old_bin=$(tmux show-options -pqv -t "$id" @peon_bin) || old_bin=""
  main=$(tmux show-options -pqv -t "$id" @peon_main) || main=""
  brief=$(tmux show-options -pqv -t "$id" @peon_brief) || brief=""
  restart=$(tmux show-options -qv -t "=$session:" @peon_restart) || restart=""
  [ -n "$old_command" ] && [ -n "$old_bin" ] && [ -f "$brief" ] && [ -r "$brief" ] ||
    die "$target has no stored command or brief; launch it again"
  case $main:$restart in
    0:0|0:1|1:0|1:1) ;;
    *) die "$target has no stored main or restart setting; launch it again" ;;
  esac
  quit=$(cli_call "$old_bin" quit_command) && [ -n "$quit" ] ||
    die "$old_bin has no quit command; quit it by hand"
  if [ "$mode" = checking ]; then
    log=$(mktemp "${brief%/*}/swap.XXXXXX") || return 1
    with_pane_delivery "$id" swap_reserve_locked "$id" "$command" "$identity" "$log" || return $?
    swap_start_job "$id" "$identity" "$log" "$target" "$command" "$session"
    echo "peon-code: checking $command for $name; the swap follows when it passes"
    return 0
  fi
  if probe=$(cli_call "$BIN" probe_command "$BIN" "$ARGS"); then
    (cd -- "$project_dir" && swap_check "$probe" "$command") || return $?
  else
    echo "peon-code: no check for $BIN; swapping on the PATH check only"
  fi
  NAMES=("$name")
  MAIN=1
  [ "$main" != 1 ] || MAIN=0
  NORMAL_SETTINGS="${brief%/*}/normal-screen.json"
  DENY_SETTINGS="${brief%/*}/deny-git.json"
  if [ "$BIN" = claude ]; then
    case "$ARGS " in
      *" --settings "*|*" --settings="*) ;;
      *) if [ "$MAIN" -eq 0 ]; then
           [ -r "$NORMAL_SETTINGS" ] || die "no stored Claude settings; launch it again"
         else
           [ -r "$DENY_SETTINGS" ] || die "no stored Claude settings; launch it again"
         fi ;;
    esac
  fi
  Q="\"\$(cat $(printf %q "$brief"))\""
  LAUNCH=$(cli_call "$BIN" launch_command "$BIN" "$ARGS" "" "$Q" "$i") || die "could not build the swap command"
  [ -n "$LAUNCH" ] || die "could not build the swap command"
  pane_identity_matches "$id" && swap_owner_matches "$id" || die "no swap: agent changed"
  if ! (
    cd -- "$project_dir" || exit 1
    physical_dir=$(pwd -P) || exit 1
    project_dirs=("$physical_dir")
    [ "$physical_dir" = "$PWD" ] || project_dirs+=("$PWD")
    cli_call "$BIN" trust_project "${project_dirs[@]}"
  ); then
    echo "peon-code: could not set $BIN project trust; continuing the swap" >&2
  fi
  pane_identity_matches "$id" && swap_owner_matches "$id" || die "no swap: agent changed"
  with_pane_delivery "$id" swap_commit_locked || return $?
  for ((wait_count = 0; wait_count < 30; wait_count++)); do
    pane_identity_matches "$id" && swap_owner_matches "$id" || return 1
    current=$(tmux display -pt "$id" '#{pane_current_command}') || die "cannot read pane $id"
    case $current in sh|bash|zsh|fish|dash|ksh) break ;; esac
    sleep 1
  done
  if [ "$wait_count" -eq 30 ]; then
    with_pane_delivery "$id" swap_abort_locked "$id" || true
    die "$name did not quit within 30 seconds"
  fi
  with_pane_delivery "$id" swap_confirm_locked "$id" || return 1
  if [ "$restart" = 1 ]; then
    echo "peon-code: $name quits; the watcher restarts it as $command"
    return 0
  fi
  # shellcheck source=lib/watch.sh
  declare -F watch_restart >/dev/null || source "$SCRIPT_DIR/lib/watch.sh"
  (cd -- "$project_dir" && watch_restart "$session" "$id" "$name" "" "$LAUNCH") || die "could not restart $name"
}

swap_commit_locked() {
  local backup options option
  local option_names=(@peon_cmd @peon_bin @peon_launch @peon_fresh @peon_weekly @peon_usage)
  pane_identity_matches "$id" && swap_owner_matches "$id" || return 1
  backup=$(mktemp -d "$brief.backup.XXXXXX") || return 1
  cp "$brief" "$backup/brief" || return 1
  printf '%s\n' "$brief" >"$backup/path"
  printf '%s\n' "${SWAP_OWNER:-}" >"$backup/owner"
  tmux display-message -p -t "$id" '#{pid}:#{session_id}:#{pane_pid}' >"$backup/identity" || return 1
  options=$(tmux show-options -p -t "$id") || return 1
  for option in "${option_names[@]}"; do
    if printf '%s\n' "$options" | awk -v key="$option" '$1 == key { found=1 } END { exit !found }'; then
      tmux show-options -pqv -t "$id" "$option" >"$backup/${option#@}" || return 1
    fi
  done
  tmux set -pt "$id" @peon_swap_backup "$backup" || return 1
  sender="$old_bin $name"
  [ "$name" != "$old_command" ] || sender=$old_bin
  temp=$(mktemp "$brief.swap.XXXXXX") || die "could not prepare the swap brief"
  if ! SWAP_OLD_CMD="$old_command" SWAP_NEW_CMD="$command" SWAP_OLD_FROM="$sender" SWAP_NEW_FROM="$BIN $name" SWAP_NAME="$name" SWAP_ID="$id" \
    awk '
      function replace(text, old, new, result, pos) {
        result = ""
        while ((pos = index(text, old)) > 0) {
          result = result substr(text, 1, pos - 1) new
          text = substr(text, pos + length(old))
        }
        return result text
      }
      BEGIN {
        name = ENVIRON["SWAP_NAME"]; id = ENVIRON["SWAP_ID"]
        old = ENVIRON["SWAP_OLD_CMD"]; new = ENVIRON["SWAP_NEW_CMD"]
        head = "You are " name " (" old "),"
        short = "You are " name ","
        roster = "pane " id ": " name " (" old ")"
        from = "[from " ENVIRON["SWAP_OLD_FROM"] " " id "]"
        to = "[from " ENVIRON["SWAP_NEW_FROM"] " " id "]"
      }
      {
        line = $0
        if (NR == 1 && index(line, head) == 1)
          line = "You are " name " (" new ")," substr(line, length(head) + 1)
        else if (NR == 1 && name == old && index(line, short) == 1)
          line = "You are " name " (" new ")," substr(line, length(short) + 1)
        if (index(line, roster) == 1)
          line = "pane " id ": " name " (" new ")" substr(line, length(roster) + 1)
        print replace(line, from, to)
      }
    ' "$brief" >"$temp" || ! mv "$temp" "$brief"; then
    die "could not update the swap brief"
  fi
  tmux set -pt "$id" @peon_cmd "$command" || die "could not store the swap command"
  tmux set -pt "$id" @peon_bin "$BIN" || die "could not store the swap CLI"
  tmux set -pt "$id" @peon_launch "$LAUNCH" || die "could not store the swap launch"
  [ "$old_bin" = "$BIN" ] || fresh=1
  tmux set -pt "$id" @peon_fresh "$fresh" || die "could not store the swap resume setting"
  tmux set -pu -t "$id" @peon_weekly || return 1
  tmux set -pu -t "$id" @peon_usage || return 1
  tmux set -pt "$id" @peon_swap_pending "waiting ${SWAP_JOB_PID:-$(exec sh -c 'echo "$PPID"')}:$(date +%s) $command" || return 1
  if ! swap_quit_locked "$id" "$old_bin" "$quit"; then
    swap_abort_locked "$id" || true
    return 1
  fi
}

swap_restore_locked() {
  local id=$1 backup path identity owner option value
  pane_identity_matches "$id" && swap_owner_matches "$id" || return 1
  backup=$(tmux show-options -pqv -t "$id" @peon_swap_backup 2>/dev/null) || backup=""
  [ -n "$backup" ] || return 0
  [ -d "$backup" ] && [ ! -L "$backup" ] && [ -O "$backup" ] || return 1
  IFS= read -r path <"$backup/path" || return 1
  IFS= read -r identity <"$backup/identity" || return 1
  IFS= read -r owner <"$backup/owner" || return 1
  [ "$(tmux display-message -p -t "$id" '#{pid}:#{session_id}:#{pane_pid}')" = "$identity" ] &&
    [ "$(tmux show-options -pqv -t "$id" @peon_swap_owner)" = "$owner" ] &&
    [ "$(tmux show-options -pqv -t "$id" @peon_brief)" = "$path" ] || return 1
  cp "$backup/brief" "$path" || return 1
  for option in peon_cmd peon_bin peon_launch peon_fresh peon_weekly peon_usage; do
    if [ -f "$backup/$option" ]; then
      value=$(cat "$backup/$option"; printf x)
      value=${value%x}
      value=${value%$'\n'}
      tmux set -pt "$id" "@$option" "$value" || return 1
    else
      tmux set -pu -t "$id" "@$option" || return 1
    fi
  done
  swap_discard_backup_locked "$id"
}

swap_discard_backup_locked() {
  local id=$1 backup
  pane_identity_matches "$id" && swap_owner_matches "$id" || return 1
  backup=$(tmux show-options -pqv -t "$id" @peon_swap_backup 2>/dev/null) || backup=""
  [ -n "$backup" ] || return 0
  rm -f "$backup/brief" "$backup/path" "$backup/owner" "$backup/identity" \
    "$backup/peon_cmd" "$backup/peon_bin" "$backup/peon_launch" "$backup/peon_fresh" "$backup/peon_weekly" "$backup/peon_usage"
  rmdir "$backup" || return 1
  tmux set -pu -t "$id" @peon_swap_backup
}

swap_abort_locked() {
  local current pending status claim pid watcher
  pane_identity_matches "$1" && swap_owner_matches "$1" || return 1
  pending=$(tmux show-options -pqv -t "$1" @peon_swap_pending 2>/dev/null) || pending=""
  case $pending in running\ *) return 1 ;; esac
  if [ -n "${SWAP_JOB_PID:-}" ]; then
    claim=${pending#waiting }
    pid=${claim%%:*}
    if [ "$pid" != "$SWAP_JOB_PID" ]; then
      watcher=$(tmux show-options -qv -t "=$(tmux display -pt "$1" '#{session_name}'):" @peon_watch_pid 2>/dev/null) || watcher=""
      [ "$pid" != "$watcher" ] || return 1
    fi
  fi
  if [ -z "$pending" ]; then
    status=$(tmux show-options -pqv -t "$1" @peon_swap 2>/dev/null) || status=""
    case $status in done\ *|failed:*) return 1 ;; esac
  fi
  current=$(tmux display -pt "$1" '#{pane_current_command}') || return 1
  case $current in
    sh|bash|zsh|fish|dash|ksh|systemd-run) swap_discard_backup_locked "$1" || return 1 ;;
    *) swap_restore_locked "$1" || return 1 ;;
  esac
  tmux set -pu -t "$1" @peon_swap_pending || return 1
  tmux set -pu -t "$1" @peon_swap_pid
}

swap_confirm_locked() {
  local current backup
  pane_identity_matches "$1" && swap_owner_matches "$1" || return 1
  current=$(tmux display -pt "$1" '#{pane_current_command}') || return 1
  backup=$(tmux show-options -pqv -t "$1" @peon_swap_backup 2>/dev/null) || backup=""
  [ -n "$backup" ] || return 0
  case $current in sh|bash|zsh|fish|dash|ksh|systemd-run) swap_discard_backup_locked "$1" ;; *) return 1 ;; esac
}

swap_handoff_locked() {
  local pending pid
  pane_identity_matches "$1" && swap_owner_matches "$1" || return 1
  pending=$(tmux show-options -pqv -t "$1" @peon_swap_pending 2>/dev/null) || pending=""
  case $pending in waiting\ *) ;; *) return 0 ;; esac
  pid=$(tmux show-options -qv -t "=$2:" @peon_watch_pid 2>/dev/null) || pid=""
  case $pid in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  tmux set -pt "$1" @peon_swap_pending "waiting $pid:$(date +%s) ${pending#* * }"
}

# Read stored metadata, since a custom role file may no longer exist.
add_roster_line() {
  local index=$1 id=${PANE_IDS[$1]} type line
  type=$(tmux show-options -pqv -t "$id" @peon_role_type)
  line="pane $id: ${NAMES[$index]} (${CMDS[$index]}) - $(tmux show-options -pqv -t "$id" @peon_role_label)"
  [ -z "$type" ] || line+=" ($type): $(tmux show-options -pqv -t "$id" @peon_role_desc)"
  if [ "${#TEAM_NAMES[@]}" -gt 1 ] && [ -n "${TEAMS[$index]}" ]; then line+=" [team ${TEAMS[$index]}]"; fi
  printf '%s\n' "$line"
}

load_session_agents() {
  local panes id name team index brief_file
  panes=$(tmux list-panes -s -t "=$SESSION" -F '#{pane_id} #{@peon_name}') || die "cannot list panes in session $SESSION"
  NAMES=(); CMDS=(); ROLES=(); PANE_IDS=(); RESUME_IDS=(); TEAMS=(); TEAM_NAMES=("$SESSION"); briefs=()
  MAIN=0; BRIEF_DIR=""; ROSTER=""
  while read -r id name; do
    [ -n "$name" ] || continue
    index=${#NAMES[@]}
    NAMES+=("$name"); PANE_IDS+=("$id"); RESUME_IDS+=("")
    CMDS+=("$(tmux show-options -pqv -t "$id" @peon_cmd)")
    ROLES+=("$(tmux show-options -pqv -t "$id" @peon_role)")
    team=$(tmux show-options -pqv -t "$id" @peon_team)
    if [ "$name" != director ]; then
      team=${team:-$SESSION}
      case " ${TEAM_NAMES[*]} " in *" $team "*) ;; *) TEAM_NAMES+=("$team") ;; esac
    fi
    TEAMS+=("$team")
    [ "$(tmux show-options -pqv -t "$id" @peon_main)" != 1 ] || MAIN=$index
    [ -n "$BRIEF_DIR" ] || BRIEF_DIR=$(tmux show-options -pqv -t "$id" @peon_brief_dir)
    brief_file=$(tmux show-options -pqv -t "$id" @peon_brief)
    [ -f "$brief_file" ] || die "${NAMES[$index]} has no stored brief; launch it again"
    briefs+=("$brief_file")
  done <<<"$panes"
  [ ${#NAMES[@]} -gt 0 ] || die "no agent panes in session $SESSION"
  [ -d "$BRIEF_DIR" ] || die "session $SESSION has no stored brief directory; launch it again"
  for index in "${!NAMES[@]}"; do ROSTER+="$(add_roster_line "$index")"$'\n'; done
}

team_config_path() {
  local conf=$1 team=$2 dir kind name path
  dir=$(cd -- "$(dirname -- "$conf")" && pwd) || return 1
  while read -r kind name path || [ -n "$kind" ]; do
    [ "$kind" = team ] || continue
    case $path in /*) ;; *) path="$dir/$path" ;; esac
    if [ "$name" = "$team" ]; then printf '%s\n' "$path"; return; fi
  done <"$conf"
  return 1
}

add_saved_role() {
  local path=$1 conf_dir=$2
  saved_role=-; role_target=""
  [ -n "$path" ] || return 0
  saved_role=$(role_label "$path")
  [[ $saved_role =~ ^[A-Za-z0-9_-]+$ ]] || die "cannot save role name: $saved_role"
  if [ "$path" != "$SCRIPT_DIR/roles/$saved_role.md" ]; then
    [ ! -f "$SCRIPT_DIR/roles/$saved_role.md" ] || die "cannot save custom role named $saved_role; a shipped role has that name"
    role_target="$conf_dir/roles/$saved_role.md"
    if [ -e "$role_target" ] || [ -L "$role_target" ]; then
      cmp -s "$path" "$role_target" || die "role file already exists with different content: $role_target"
    fi
  fi
}

session_config_path() {
  local mode=$1 conf
  conf=$(tmux show-options -qv -t "$SESSION" @peon_conf)
  if [ "$mode" = source ]; then
    conf=${CONF:-$conf}
    [ -n "$conf" ] || die "add-team needs -c <file> or a saved session config"
    [ -f "$conf" ] || die "config file not found: $conf"
    printf '%s/%s\n' "$(cd -- "$(dirname -- "$conf")" && pwd)" "$(basename -- "$conf")"
  else
    case $conf in
      "$HOME/.config/peon-code/peon-code.conf") conf="" ;;
      "$project_dir"/*) [ -f "$conf" ] || conf="" ;;
      *) conf="" ;;
    esac
    printf '%s\n' "$conf"
  fi
}

add_lock() {
  local panes id lock owner stale
  panes=$(tmux list-panes -s -t "=$SESSION" -F '#{pane_id} #{@peon_brief_dir}') || die "cannot list panes in session $SESSION"
  BRIEF_DIR=""
  while read -r id BRIEF_DIR; do
    [ ! -d "$BRIEF_DIR" ] || break
  done <<<"$panes"
  [ -d "$BRIEF_DIR" ] || die "session $SESSION has no stored brief directory; launch it again"
  lock="$BRIEF_DIR/add.lock"
  # $$ names the parent shell in a subshell function; the child reports this holder.
  add_holder=$(exec sh -c 'echo "$PPID"')
  if ! mkdir "$lock" 2>/dev/null; then
    owner=$(cat "$lock/owner" 2>/dev/null) || owner=""
    if [[ $owner =~ ^[1-9][0-9]*$ ]] && ! kill -0 "$owner" 2>/dev/null && mkdir "$lock/reclaim" 2>/dev/null; then
      # Recheck under the reclaim guard before moving the stale directory aside.
      if [ "$(cat "$lock/owner" 2>/dev/null)" = "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
        stale=$(mktemp -d "$BRIEF_DIR/add-stale.XXXXXX") || die "cannot reclaim add lock: $lock"
        mv "$lock" "$stale/lock" || die "cannot reclaim add lock: $lock"
        rm -f "$stale/lock/owner"
        rmdir "$stale/lock/reclaim" "$stale/lock" "$stale" || die "cannot remove stale add lock: $stale/lock"
      else
        rmdir "$lock/reclaim" 2>/dev/null || true
      fi
    fi
    mkdir "$lock" 2>/dev/null || die "another add or add-team is running in session $SESSION; retry after it finishes. Lock: $lock; remove it only when no add or add-team is running"
  fi
  printf '%s\n' "$add_holder" >"$lock/owner" || { rmdir "$lock" 2>/dev/null || true; die "cannot write add lock owner: $lock"; }
  trap add_cleanup EXIT
}

add_cleanup() {
  local pane board
  if [ "$committed" -eq 0 ]; then
    for pane in ${created_panes[@]+"${created_panes[@]}"}; do tmux kill-pane -t "$pane" 2>/dev/null || true; done
    for board in ${created_boards[@]+"${created_boards[@]}"}; do rm -f "$board"; done
    tmux select-layout -t "$SESSION":agents main-vertical >/dev/null 2>&1 || true
  fi
  if [ "$(cat "$BRIEF_DIR/add.lock/owner" 2>/dev/null)" = "$add_holder" ]; then
    rm -f "$BRIEF_DIR/add.lock/owner"
    rmdir "$BRIEF_DIR/add.lock"
  fi
}

add_brief_note() {
  local brief=$1 note=$2 temporary
  temporary=$(mktemp "$brief.XXXXXX") || die "could not update brief: $brief"
  { cat "$brief" && printf '\n%s\n' "$note"; } >"$temporary" &&
    mv "$temporary" "$brief" || die "could not update brief: $brief"
}

add_config_append() {
  local conf=$1
  temporary=$(mktemp "$conf.XXXXXX") || die "cannot save config: $conf"
  if [ -f "$conf" ]; then
    cat "$conf" >"$temporary" || die "cannot read config: $conf"
    [ ! -s "$conf" ] || [ -z "$(tail -c1 "$conf")" ] || printf '\n' >>"$temporary"
  fi
}

add_split_pane() {
  local index=$1 layout=$2 pane
  pane=$(tmux split-window -d -P -F '#{pane_id}' -t "$SESSION":agents -c "$PWD" \
    -e "PEON_CODE_SESSION=$SESSION" -e DISABLE_AUTO_UPDATE=true -e CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1) || die "could not add a pane to session $SESSION"
  PANE_IDS[index]=$pane; created_panes+=("$pane")
  tmux select-layout -t "$SESSION":agents "$layout" >/dev/null || true
  initialize_agent_pane "$index"
  wait_shell_ready "$pane"
}

add_copy_role() {
  local path=$1 target=$2
  [ -n "$target" ] || return 0
  if [ -e "$target" ] || [ -L "$target" ]; then
    cmp -s "$path" "$target" || die "role file already exists with different content: $target"
  else
    mkdir -p "$(dirname -- "$target")" && cp "$path" "$target" || die "cannot save role: $target"
  fi
}

add_root_roles() {
  local count=$1 conf_dir=$2 index label type
  root_roles=()
  for ((index = 0; index < count; index++)); do
    label=$(tmux show-options -pqv -t "${PANE_IDS[$index]}" @peon_role_label)
    type=$(tmux show-options -pqv -t "${PANE_IDS[$index]}" @peon_role_type)
    if [ -n "$type" ]; then
      [ -f "$SCRIPT_DIR/roles/$label.md" ] || [ -f "$conf_dir/roles/$label.md" ] ||
        die "cannot save agent ${NAMES[$index]}: missing role $label; write roles/$label.md next to the config first"
    else label=-; fi
    root_roles+=("$label")
  done
}

add_restart_watcher() {
  local restart threshold watcher watcher_args=""
  restart=$(tmux show-options -qv -t "$SESSION" @peon_restart)
  threshold=$(tmux show-options -qv -t "$SESSION" @peon_compact_at)
  if [ "${threshold:-0}" -gt 0 ] || [ "$restart" = 1 ]; then
    watcher=$(tmux show-options -qv -t "$SESSION" @peon_watch_pid)
    if [[ $watcher =~ ^[1-9][0-9]*$ ]]; then
      watcher_args=$(ps -ww -o args= -p "$watcher" 2>/dev/null) || watcher_args=""
    fi
    case " $watcher_args " in
      *"/peon-code.sh watch $SESSION "*|*" peon-code.sh watch $SESSION "*) ;;
      *) nohup "$SCRIPT_DIR/peon-code.sh" watch "$SESSION" "${threshold:-0}" >/dev/null 2>>"$BRIEF_DIR/watch.log" </dev/null & ;;
    esac
  fi
}

cmd_add() (
  local session=${PEON_CODE_SESSION:-} name role command argument path type id known index
  local new_line new_pane project_dir brief_file temporary has_roles=0 committed=0 add_holder
  local save=0 rebuild=0 conf conf_dir saved_role role_target="" marker team="" saved_name
  local fields=() briefs=() root_roles=() created_panes=() created_boards=()
  while [ $# -gt 0 ]; do
    case $1 in
      --save) save=1; shift ;;
      --team)
        [ $# -ge 2 ] && [ -n "$2" ] || die "--team needs a team name"
        team=$2; shift 2 ;;
      --session)
        [ $# -ge 2 ] && [ -n "$2" ] || die "--session needs a session name"
        session=$2; shift 2 ;;
      *) fields+=("$1"); shift ;;
    esac
  done
  [ ${#fields[@]} -ge 3 ] || die "usage: peon-code.sh add <name> <role> <command...> [--team <name>] [--session <name>] [--save]"
  name=${fields[0]}; role=${fields[1]}; command=${fields[2]}
  [ ${#fields[@]} -le 3 ] || for argument in "${fields[@]:3}"; do command+=" $(printf %q "$argument")"; done
  [[ $name =~ ^[A-Za-z0-9_-]+$ ]] || die "name \"$name\" must be letters, digits, _ or -"
  [ "$name" != director ] || die "name director is reserved"
  saved_name=$name
  [ -n "${command//[[:space:]]/}" ] || die "add needs an agent command"
  SESSION=$(session_name "$session")
  tmux has-session -t "=$SESSION" 2>/dev/null || die "no session $SESSION"
  is_peon_session "$SESSION" || die "session $SESSION was not created by peon-code"
  path=$(resolve_role "$role" "$PWD")
  [ -z "$path" ] || [ -f "$path" ] || die "role file not found: $path"
  type=$(role_field "$path" type)
  if [ -n "$path" ]; then
    case $type in
      director) die "add refuses a director-type role; use add-team" ;;
      manager|worker|reviewer) ;;
      *) die "role file $path needs a frontmatter type: manager, worker, or reviewer" ;;
    esac
  fi
  add_lock
  load_session_agents
  if [ -z "$team" ] && [ -n "${TMUX_PANE:-}" ]; then
    for index in "${!PANE_IDS[@]}"; do
      [ "${PANE_IDS[$index]}" != "$TMUX_PANE" ] || team=${TEAMS[$index]}
    done
  fi
  team=${team:-$SESSION}
  case " ${TEAM_NAMES[*]} " in *" $team "*) ;; *) die "no team named $team in session $SESSION" ;; esac
  [ "$team" = "$SESSION" ] || name="$team-$name"
  for index in "${!NAMES[@]}"; do
    known=${NAMES[$index]}; id=${PANE_IDS[$index]}
    [ "$known" != "$name" ] || die "name \"$name\" is used twice"
    [ "${TEAMS[$index]}" = "$team" ] || continue
    role=$(tmux show-options -pqv -t "$id" @peon_role_type)
    [ -z "$role" ] || has_roles=1
    [ "$type:$role" != manager:manager ] || die "session $SESSION already has a manager"
  done
  [ -z "$type" ] || [ "$has_roles" -eq 1 ] || die "session $SESSION has no roles; add a roleless agent (-) or launch a role team"
  project_dir=$(tmux show-options -qv -t "$SESSION" @peon_project_dir)
  if [ "$save" -eq 1 ]; then
    conf=$(session_config_path save) || exit 1
    if [ "$team" != "$SESSION" ]; then
      [ -n "$conf" ] || die "save the team config before adding an agent with --save"
      conf=$(team_config_path "$conf" "$team") || die "no saved config for team $team; save the team first"
      [ -f "$conf" ] || die "config file not found: $conf"
    fi
    if [ -z "$conf" ]; then
      [ "${#TEAM_NAMES[@]}" -le 1 ] || die "save existing teams before rebuilding the session config"
      rebuild=1
      conf="$project_dir/peon-code.conf"
      [ ! -e "$conf" ] && [ ! -L "$conf" ] || die "config already exists but was not used by this session: $conf"
    fi
    conf_dir=$(cd -- "$(dirname -- "$conf")" && pwd)
    if [ ! -f "$conf" ]; then
      add_root_roles "${#NAMES[@]}" "$conf_dir"
    fi
    add_saved_role "$path" "$conf_dir"
  fi
  cd -- "$project_dir" || die "cannot enter session project directory: $project_dir"
  prepare_launch_settings
  index=${#NAMES[@]}
  resize_headless_agents "$SESSION" "$((index + 1))"
  NAMES+=("$name"); CMDS+=("$command"); ROLES+=("$path"); RESUME_IDS+=("")
  TEAMS+=("$team")
  N=${#NAMES[@]}
  add_split_pane "$index" main-vertical
  new_pane=${PANE_IDS[$index]}
  new_line=$(add_roster_line "$index")
  ROSTER+="$new_line"$'\n'
  FAILED_AGENTS=()
  if ! launch_agents "$index" "pane-${new_pane#%}" || [ ${#FAILED_AGENTS[@]} -gt 0 ]; then
    die "agent $name failed to start; killed new pane $new_pane"
  fi
  committed=1
  for brief_file in "${briefs[@]}"; do
    add_brief_note "$brief_file" "New teammate, add to the roster above: $new_line"
  done
  for ((index = 0; index < N - 1; index++)); do
    if ! cmd_send "${PANE_IDS[$index]}" "[from peon-code] New teammate: $new_line"; then
      echo "peon-code: could not notify ${NAMES[$index]} ${PANE_IDS[$index]} about $name" >&2
    fi
  done
  if [ "$save" -eq 1 ]; then
    if [ "$rebuild" -eq 1 ] && { [ -e "$conf" ] || [ -L "$conf" ]; }; then
      die "config already exists but was not used by this session: $conf"
    fi
    add_copy_role "$path" "$role_target"
    add_config_append "$conf"
    if [ ! -f "$conf" ]; then
      for ((index = 0; index < N - 1; index++)); do
        marker=""
        [ "$index" -ne "$MAIN" ] || marker='*'
        printf '%s%s %s %s\n' "$marker" "${NAMES[$index]}" "${CMDS[$index]}" "${root_roles[$index]}" >>"$temporary" || die "cannot write config: $conf"
      done
    fi
    printf '%s %s %s\n' "$saved_name" "$command" "$saved_role" >>"$temporary" &&
      mv "$temporary" "$conf" || die "cannot save config: $conf"
    if [ "$team" = "$SESSION" ]; then tmux set-option -t "$SESSION" @peon_conf "$conf"; fi
  fi
  add_restart_watcher
  echo "peon-code: added $name $new_pane to session $SESSION"
)

add_team_convert_director() {
  local pane first order index bin args brief_file q line
  if [ "$new_director" -eq 1 ]; then
    pane=${PANE_IDS[$director]}
    first=$(tmux list-panes -t "$SESSION":agents -F '#{pane_id}' | head -1)
    [ "$first" = "$pane" ] || tmux swap-pane -d -s "$pane" -t "$first"
    order=$(tmux show-options -qv -t "$SESSION" @peon_pane_order)
    [ -z "$order" ] || tmux set-option -t "$SESSION" @peon_pane_order "$pane $order"
    for ((index = 0; index < old_count; index++)); do tmux set -pt "${PANE_IDS[$index]}" @peon_team "$SESSION"; done
    tmux set -pt "${PANE_IDS[$old_main]}" @peon_main 0
    bin=${CMDS[$old_main]%% *}; args=""
    [ "${CMDS[$old_main]}" = "$bin" ] || args=" ${CMDS[$old_main]#* }"
    brief_file=$(tmux show-options -pqv -t "${PANE_IDS[$old_main]}" @peon_brief)
    q="\"\$(cat $(printf %q "$brief_file"))\""
    if ! line=$(cli_call "$bin" launch_command "$bin" "$args" "" "$q" "$old_main") || [ -z "$line" ] ||
      ! tmux set -pt "${PANE_IDS[$old_main]}" @peon_launch "$line"; then
      tmux set -pu -t "${PANE_IDS[$old_main]}" @peon_launch
      echo 'peon-code: cannot update the manager restart command; automatic restart disabled for that pane; swap it before restarting' >&2
    fi
    notice="This replaces rules 1 and 2 above: a director now runs intake and git in pane $pane (director). Your team is $SESSION: the roster lines above without a [team] tag. Message only your own team and the director. Where rules 3, 4, and 5 say tell the user, tell the director instead. Team managers report plan rows to the director as D<n> done, never to the user, and the director posts the final summary. The session now has a director: never run git commit, git stash, or any history-rewriting git command; request commits from the director by message. The commit pane is now $pane."
    printf 'peon-code: manager %s keeps git until it is swapped or restarted\n' "${NAMES[$old_main]}"
  fi
}

add_team_save() {
  local index target temporary team_temp team_entry marker known path
  if [ "$save" -eq 1 ]; then
    if [ "$rebuild" -eq 1 ] && { [ -e "$conf" ] || [ -L "$conf" ]; }; then
      die "config already exists but was not used by this session: $conf"
    fi
    team_temp=$(mktemp "$team_file.XXXXXX") || die "cannot save team config: $team_file"
    for ((index = old_count; index < N; index++)); do
      [ "$index" -ne "$director" ] || continue
      target=${role_targets[$index]}
      add_copy_role "${ROLES[$index]}" "$target"
      printf '%s %s %s\n' "${NAMES[$index]#"$team-"}" "${CMDS[$index]}" "${saved_roles[$index]}" >>"$team_temp" || die "cannot save team config: $team_file"
    done
    [ ! -e "$team_file" ] && [ ! -L "$team_file" ] || die "team config already exists: $team_file"
    mv "$team_temp" "$team_file" || die "cannot save team config: $team_file"
    add_config_append "$conf"
    if [ ! -f "$conf" ]; then
      for ((index = 0; index < old_count; index++)); do
        [ "${TEAMS[$index]}" = "$SESSION" ] || continue
        marker=""; [ "$index" -ne "$old_main" ] || marker='*'
        printf '%s%s %s %s\n' "$marker" "${NAMES[$index]}" "${CMDS[$index]}" "${root_roles[$index]}" >>"$temporary" || die "cannot write config: $conf"
      done
      for known in "${TEAM_NAMES[@]}"; do
        [ "$known" != "$SESSION" ] && [ "$known" != "$team" ] || continue
        path="$project_dir/peon-code.$known.conf"
        team_temp=$(mktemp "$path.XXXXXX") || die "cannot save team config: $path"
        for ((index = 0; index < old_count; index++)); do
          [ "${TEAMS[$index]}" = "$known" ] || continue
          printf '%s %s %s\n' "${NAMES[$index]#"$known-"}" "${CMDS[$index]}" "${root_roles[$index]}" >>"$team_temp" || die "cannot save team config: $path"
        done
        [ ! -e "$path" ] && [ ! -L "$path" ] || die "team config already exists: $path"
        mv "$team_temp" "$path" || die "cannot save team config: $path"
        printf 'team %s %s\n' "$known" "${path##*/}" >>"$temporary"
      done
    fi
    team_entry=$team_file
    case $conf_dir in
      "$project_dir"|"$project_dir"/*)
        team_entry=${team_file##*/}; path=${conf_dir#"$project_dir"}
        while [ -n "$path" ]; do team_entry="../$team_entry"; path=${path%/*}; done ;;
    esac
    printf 'team %s %s\n' "$team" "$team_entry" >>"$temporary"
    mv "$temporary" "$conf" || die "cannot save config: $conf"
    tmux set-option -t "$SESSION" @peon_conf "$conf"
  fi
}

cmd_add_team() (
  local session=${PEON_CODE_SESSION:-} team="" save=0 rebuild=0 argument source_conf director_command
  local project_dir conf conf_dir team_file saved_role role_target
  local index old_count old_main director=-1 new_director=0 known pane board team_number
  local brief_file additions="" notice="" path j line committed=0 add_holder
  local briefs=() created_panes=() created_boards=() indices=() saved_roles=() role_targets=() root_roles=()
  while [ $# -gt 0 ]; do
    case $1 in
      --save) save=1; shift ;;
      --team|--session)
        argument=$1
        [ $# -ge 2 ] && [ -n "$2" ] || die "$argument needs a name"
        if [ "$argument" = --team ]; then team=$2; else session=$2; fi
        shift 2 ;;
      *) die "unknown add-team argument: $1" ;;
    esac
  done
  SESSION=$(session_name "$session")
  tmux has-session -t "=$SESSION" 2>/dev/null || die "no session $SESSION"
  is_peon_session "$SESSION" || die "session $SESSION was not created by peon-code"
  source_conf=$(session_config_path source) || exit 1
  add_lock
  load_session_agents
  if [ -z "$team" ]; then
    team_number=2
    while :; do
      team="team$team_number"
      case " ${TEAM_NAMES[*]} " in
        *" $team "*) team_number=$((team_number + 1)) ;;
        *) break ;;
      esac
    done
  fi
  [[ $team =~ ^[A-Za-z0-9_-]+$ ]] || die "team name \"$team\" must be letters, digits, _ or -"
  [ "$team" != director ] || die "team name director is reserved"
  case " ${TEAM_NAMES[*]} " in *" $team "*) die "team name \"$team\" is used twice" ;; esac
  old_count=${#NAMES[@]}; old_main=$MAIN
  for index in "${!NAMES[@]}"; do [ "${NAMES[$index]}" != director ] || director=$index; done
  TEAM_NAMES+=("$team")
  read_conf "$source_conf" 1 "$team"
  for ((index = old_count; index < ${#NAMES[@]}; index++)); do
    [ "${TEAMS[$index]}" = "$team" ] || die "add-team config must describe one team"
    [ "$(role_field "${ROLES[$index]}" type)" != director ] || die "add-team reserves the director-type role for the director pane"
    RESUME_IDS+=("")
  done
  if [ "$director" -lt 0 ]; then
    new_director=1
    [ "$(tmux show-options -pqv -t "${PANE_IDS[$old_main]}" @peon_role_type)" = manager ] ||
      die "main pane ${NAMES[$old_main]} is not a manager; launch a session with its manager as main before add-team"
    director_command=${CMDS[$old_main]}
    path="$SCRIPT_DIR/roles/director.md"
    [ -f "$path" ] && [ "$(role_field "$path" type)" = director ] || die "director role file not found or invalid: $path"
    director=${#NAMES[@]}
    NAMES+=(director); CMDS+=("$director_command"); ROLES+=("$path"); TEAMS+=(""); RESUME_IDS+=("")
    indices+=("$director")
  fi
  MAIN=$director; N=${#NAMES[@]}
  for ((index = old_count; index < N; index++)); do [ "$index" -eq "$director" ] || indices+=("$index"); done
  ROSTER=""
  for ((index = 0; index < old_count; index++)); do ROSTER+="$(add_roster_line "$index")"$'\n'; done
  project_dir=$(tmux show-options -qv -t "$SESSION" @peon_project_dir)
  if [ "$save" -eq 1 ]; then
    conf=$(session_config_path save) || exit 1
    if [ -z "$conf" ]; then
      rebuild=1
      conf="$project_dir/peon-code.conf"
      [ ! -e "$conf" ] && [ ! -L "$conf" ] || die "config already exists but was not used by this session: $conf"
      add_root_roles "$old_count" "$project_dir"
      for known in "${TEAM_NAMES[@]}"; do
        [ "$known" != "$SESSION" ] && [ "$known" != "$team" ] || continue
        path="$project_dir/peon-code.$known.conf"
        [ ! -e "$path" ] && [ ! -L "$path" ] || die "team config already exists: $path"
      done
    fi
    conf_dir=$(cd -- "$(dirname -- "$conf")" && pwd)
    team_file="$project_dir/peon-code.$team.conf"
    [ ! -e "$team_file" ] && [ ! -L "$team_file" ] || die "team config already exists: $team_file"
    for ((index = old_count; index < N; index++)); do
      [ "$index" -ne "$director" ] || continue
      add_saved_role "${ROLES[$index]}" "$project_dir"
      saved_roles[index]=$saved_role; role_targets[index]=$role_target
      for ((j = old_count; j < index; j++)); do
        if [ -n "$role_target" ] && [ "${role_targets[$j]:-}" = "$role_target" ]; then
          cmp -s "${ROLES[$index]}" "${ROLES[$j]}" || die "role file already exists with different content: $role_target"
        fi
      done
    done
  fi
  cd -- "$project_dir" || die "cannot enter session project directory: $project_dir"
  prepare_launch_settings
  resize_headless_agents "$SESSION" "$N"
  for index in "${indices[@]}"; do
    add_split_pane "$index" tiled
    line=$(add_roster_line "$index")
    ROSTER+="$line"$'\n'; additions+="$line"$'\n'
    board=$(board_for "$index")
    [ -f "$board" ] || created_boards+=("$PWD/$board")
    seed_board "$index"
  done
  FAILED_AGENTS=()
  for index in "${indices[@]}"; do
    if ! launch_agents "$index" "pane-${PANE_IDS[$index]#%}" || [ ${#FAILED_AGENTS[@]} -gt 0 ]; then
      die "team $team failed to start; killed new panes: ${FAILED_AGENTS[*]}"
    fi
  done
  committed=1
  add_team_convert_director
  tmux select-layout -t "$SESSION":agents main-vertical >/dev/null || true
  for brief_file in "${briefs[@]}"; do
    add_brief_note "$brief_file" "New teammates, add to the roster above:
$additions
$notice"
  done
  (rebrief_agents all "$SESSION" "${PANE_IDS[*]:0:$old_count}") ||
    echo "peon-code: some old panes were not rebriefed; stored briefs include the new team" >&2
  add_team_save
  add_restart_watcher
  echo "peon-code: added team $team to session $SESSION"
)

cmd_swap() {
  local target=${1:-} bin=${2:-} model=${3:-} effort=${4:-} session panes pane name id="" old_bin old_command args="" field command
  [ $# -eq 4 ] || [ $# -eq 5 ] || die "usage: peon-code.sh swap <name> <cli|-> <model|-> <effort|-> [<session>]"
  for field in "$bin" "$model" "$effort"; do
    [[ $field =~ ^(-|[A-Za-z0-9._=/][A-Za-z0-9._=/-]*)$ ]] || die "swap fields must be one CLI, model, or effort token, or -"
  done
  [ "$bin:$model:$effort" != '-:-:-' ] || die "swap needs a CLI, model, or effort change"
  session=$(session_name "${5:-}")
  tmux has-session -t "=$session" 2>/dev/null || die "no session $session"
  is_peon_session "$session" || die "session $session was not created by peon-code"
  panes=$(tmux list-panes -s -t "=$session" -F '#{pane_id} #{@peon_name}') || die "cannot list panes in session $session"
  while read -r pane name; do
    [ "$name" = "$target" ] || continue
    id=$pane
    break
  done <<<"$panes"
  [ -n "$id" ] || die "no pane named $target in session $session"
  pane_identity_matches "$id" || die "no swap: agent changed"
  with_pane_delivery "$id" swap_recover_locked "$id" || die "no swap: agent changed"
  old_bin=$(tmux show-options -pqv -t "$id" @peon_bin) || old_bin=""
  old_command=$(tmux show-options -pqv -t "$id" @peon_cmd) || old_command=""
  [ -n "$old_bin" ] && [ -n "$old_command" ] || die "$target has no stored command or brief; launch it again"
  [ "$bin" != - ] || bin=$old_bin
  if [ "$bin" = "$old_bin" ] && [ "$old_command" != "$old_bin" ]; then args=" ${old_command#* }"; fi
  args=$(cli_call "$bin" swap_args "$args" "$model" "$effort") || die "swap does not know $bin"
  command="$bin$args"
  [ "$command" != "$old_command" ] || die "$target already runs $command; nothing to change"
  swap_run checking '' "$target" "$command" "$session"
}

swap_reserve_locked() {
  local PEON_EXPECTED_IDENTITY=$3 status pending pid owner started now args
  pane_identity_matches "$1" || return 1
  status=$(tmux show-options -pqv -t "$1" @peon_swap 2>/dev/null) || status=""
  pending=$(tmux show-options -pqv -t "$1" @peon_swap_pending 2>/dev/null) || pending=""
  case $pending in waiting\ *|running\ *)
    if watch_swap_reap_locked "$1"; then pending=""; status=""; fi ;;
  esac
  [ -z "$pending" ] || { echo 'peon-code: a swap is already checking for this pane' >&2; return 1; }
  case $status in checking*)
    pid=$(tmux show-options -pqv -t "$1" @peon_swap_pid 2>/dev/null) || pid=""
    owner=$(tmux show-options -pqv -t "$1" @peon_swap_owner 2>/dev/null) || owner=""
    started=$(tmux show-options -pqv -t "$1" @peon_swap_started 2>/dev/null) || started=""
    now=$(date +%s)
    case $pid in ''|*[!0-9]*) args="" ;; *) args=$(ps -ww -p "$pid" -o args= 2>/dev/null) || args="" ;; esac
    if [ -n "$owner" ] && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      case $args in *"$owner"*) echo 'peon-code: a swap is already checking for this pane' >&2; return 1 ;; esac
    fi
    case $started in ''|*[!0-9]*) started=0 ;; esac
    if [ -z "$pid" ] && [ "$((now - started))" -lt 10 ]; then
      echo 'peon-code: a swap is already checking for this pane' >&2; return 1
    fi
    local backup SWAP_OWNER=$owner
    backup=$(tmux show-options -pqv -t "$1" @peon_swap_backup 2>/dev/null) || backup=""
    [ -z "$backup" ] || swap_abort_locked "$1" || return 1 ;;
  esac
  tmux set -pt "$1" @peon_swap_owner "${4:-$3:$2}" || return 1
  tmux set -pt "$1" @peon_swap_identity "$3" || return 1
  tmux set -pt "$1" @peon_swap_started "$(date +%s)" || return 1
  tmux set -pu -t "$1" @peon_swap_pid || return 1
  tmux set -pt "$1" @peon_swap "checking $2"
}

swap_recover_locked() {
  local id=$1 pending status pid owner args started now backup
  pane_identity_matches "$id" || return 1
  pending=$(tmux show-options -pqv -t "$id" @peon_swap_pending 2>/dev/null) || pending=""
  if [ -n "$pending" ]; then
    watch_swap_reap_locked "$id" || true
    return 0
  fi
  status=$(tmux show-options -pqv -t "$id" @peon_swap 2>/dev/null) || status=""
  case $status in checking\ *) ;; *) return 0 ;; esac
  backup=$(tmux show-options -pqv -t "$id" @peon_swap_backup 2>/dev/null) || backup=""
  [ -n "$backup" ] || return 0
  pid=$(tmux show-options -pqv -t "$id" @peon_swap_pid 2>/dev/null) || pid=""
  owner=$(tmux show-options -pqv -t "$id" @peon_swap_owner 2>/dev/null) || owner=""
  started=$(tmux show-options -pqv -t "$id" @peon_swap_started 2>/dev/null) || started=0
  case $pid in ''|*[!0-9]*) args="" ;; *) args=$(ps -ww -p "$pid" -o args= 2>/dev/null) || args="" ;; esac
  if [ -n "$pid" ] && [ -n "$owner" ] && kill -0 "$pid" 2>/dev/null; then
    case $args in *"$owner"*) return 0 ;; esac
  fi
  case $started in ''|*[!0-9]*) started=0 ;; esac
  now=$(date +%s)
  [ -n "$pid" ] || [ "$((now - started))" -ge 10 ] || return 0
  local SWAP_OWNER=$owner
  swap_abort_locked "$id" || return 1
  tmux set -pt "$id" @peon_swap 'failed: swap job stopped before quit'
}

swap_status() {
  with_pane_delivery "$2" swap_status_locked "$@"
}

swap_status_locked() {
  local session=$1 id=$2 PEON_EXPECTED_IDENTITY=$3 note=$4
  pane_identity_matches "$id" && swap_owner_matches "$id" || return 1
  tmux set -pt "$id" @peon_swap "$note" || return 1
  watch_note "$session" "$note"
}

swap_owner_matches() {
  [ -z "${SWAP_OWNER:-}" ] ||
    [ "$(tmux show-options -pqv -t "$1" @peon_swap_owner 2>/dev/null)" = "$SWAP_OWNER" ]
}

swap_start_job() {
  local id=$1 identity=$2 log=$3
  local runner=()
  shift 3
  if command -v setsid >/dev/null 2>&1; then runner=(setsid); fi
  # setsid detaches the job; its entry point moves it into a safe user scope.
  if [ ${#runner[@]} -eq 0 ] && command -v nohup >/dev/null 2>&1; then runner=(nohup); fi
  ${runner[@]+"${runner[@]}"} bash "$SCRIPT_DIR/peon-code.sh" __swap_job "$id" "$identity" "$log" "$@" </dev/null >"$log" 2>&1 &
}

swap_job() {
  local id=$1 identity=$2 log=$3 target=$4 command=$5 session=$6 detail status=0
  local PEON_EXPECTED_IDENTITY=$identity
  local SWAP_OWNER=$log actual_pid SWAP_JOB_PID wait_count
  local err="$log.err" current worker="" check_pid=""
  local SWAP_CHECK_PID_FILE="$log.pid"
  actual_pid=$(exec sh -c 'echo "$PPID"')
  SWAP_JOB_PID=$actual_pid
  with_pane_delivery "$id" swap_publish_locked "$id" "$identity" "$actual_pid" || return 1
  swap_job_stop() {
    trap '' INT TERM HUP
    if [ -s "$SWAP_CHECK_PID_FILE" ]; then
      read -r check_pid <"$SWAP_CHECK_PID_FILE"
      kill -TERM "$check_pid" 2>/dev/null || true
    elif [ -n "$worker" ]; then
      kill -TERM "$worker" 2>/dev/null || true
    fi
    [ -z "$worker" ] || wait "$worker" 2>/dev/null || true
    if with_pane_delivery "$id" swap_abort_locked "$id"; then
      swap_status "$session" "$id" "$identity" 'failed: swap job interrupted' || true
    fi
    exit 143
  }
  # Capture local paths now because the job function returns before shell exit.
  trap "rm -f $(printf %q "$err") $(printf %q "$SWAP_CHECK_PID_FILE")" EXIT
  trap swap_job_stop INT TERM HUP
  # A private entry point can use a separate scope without blocking the caller.
  if [ "${7:-}" != scoped ] && command -v systemd-run >/dev/null 2>&1 &&
    systemd-run --user --scope -q -p OOMPolicy=continue -- true >/dev/null 2>&1; then
    systemd-run --user --scope -q -p OOMPolicy=continue -- bash "$SCRIPT_DIR/peon-code.sh" __swap_job "$id" "$identity" "$log" "$target" "$command" "$session" scoped &
    worker=$!
    wait "$worker" || status=$?
    worker=""
    if [ "$status" -ne 0 ] && pane_identity_matches "$id"; then
      current=$(tmux show-options -pqv -t "$id" @peon_swap 2>/dev/null) || current=""
      case $current in checking*) swap_status "$session" "$id" "$identity" 'failed: could not start the swap job' ;; esac
    fi
    return "$status"
  fi
  (swap_run apply "$id" "$target" "$command" "$session") 2>"$err" &
  worker=$!
  wait "$worker" || status=$?
  worker=""
  cat "$err" >&2
  if [ "$status" -eq 0 ]; then
    pane_identity_matches "$id" && swap_owner_matches "$id" || return 1
    for ((wait_count = 0; wait_count < 30; wait_count++)); do
      with_pane_delivery "$id" swap_handoff_locked "$id" "$session" && break
      sleep 1
    done
    if [ "$wait_count" -eq 30 ]; then
      with_pane_delivery "$id" swap_abort_locked "$id" || true
      swap_status "$session" "$id" "$identity" 'failed: no live watcher claimed the swap' || true
      status=1
    fi
  else
    detail=$(tail -n 1 "$err")
    detail=${detail#peon-code: }
    detail=${detail#"$command failed its check: "}
    detail=${detail:-swap job failed}
    if with_pane_delivery "$id" swap_abort_locked "$id"; then
      swap_status "$session" "$id" "$identity" "failed: $detail" || true
    fi
  fi
  rm -f "$err"
  return "$status"
}

swap_publish_locked() {
  local PEON_EXPECTED_IDENTITY=$2
  pane_identity_matches "$1" && swap_owner_matches "$1" || return 1
  tmux set -pt "$1" @peon_swap_pid "$3"
}

swap_quit_locked() {
  local CLI_PROMPT_MARKERS CLI_PANE_HAS_PROMPT_MARKER=1
  local CLI_PASTE_PLACEHOLDERS=()
  pane_identity_matches "$1" || return 1
  CLI_PROMPT_MARKERS=$(cli_call "$2" prompt_marker)
  CLI_PASTE_PLACEHOLDERS=("$(cli_call "$2" paste_placeholder)")
  slash_locked "$1" "$3"
}

# Return 5 before a paste, or 1 after a paste without Enter.
slash_locked() {
  local id=$1 slash=$2 box i submitted
  if ! pane_takes_keys "$id"; then
    echo "peon-code: skipped $id: it is in copy mode" >&2
    return 5
  fi
  if pane_is_busy "$id"; then
    echo "peon-code: skipped $id: it is busy with a turn" >&2
    return 5
  fi
  box=$(pane_box_text "$id") || case $? in
    2) echo "peon-code: skipped $id: it draws no prompt marker peon-code knows" >&2; return 5 ;;
    5) echo "peon-code: skipped $id: it is in shell mode" >&2; return 5 ;;
    *) echo "peon-code: skipped $id: it is on a dialog or a menu" >&2; return 5 ;;
  esac
  if [ -n "$box" ]; then
    echo "peon-code: skipped $id: its input box holds typed text" >&2
    return 5
  fi
  if [ "$slash" = /compact ]; then
    tmux set -pt "$id" @peon_compact_owned 1 || return 5
  fi
  if ! printf '%s' "$slash" | paste_only "$id"; then
    if [ "$slash" = /compact ]; then tmux set -pu -t "$id" @peon_compact_owned || true; fi
    echo "peon-code: skipped $id: tmux refused the paste" >&2
    return 5
  fi
  submitted=0
  for ((i = 0; i < 10; i++)); do
    sleep 0.2
    box=$(pane_box_text "$id") || box=""
    [ "$box" = "$slash" ] || continue
    pane_takes_keys "$id" || break
    tmux send-keys -t "$id" Enter || break
    submitted=1
    break
  done
  if [ "$submitted" -eq 0 ] && [ "$slash" = /compact ]; then
    tmux set -pu -t "$id" @peon_compact_owned || true
  fi
  [ "$submitted" -eq 1 ]
}
