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
# or never shows it is reported and the rest still get theirs; the count is of panes that took an Enter. A run where any pane
# took no message ends nonzero.
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
    Tab|Up|Down|Enter|Escape|BSpace|C-c) ;;
    *) echo "peon-code: allowed keys: Tab, Up, Down, Enter, Escape, BSpace, C-c" >&2; return 2 ;;
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
      box=$(pane_box_text "$pane") || die "no Enter sent: cannot read input box in pane $pane"
      [ -n "$box" ] || die "no Enter sent: nothing to submit"
    fi
  fi
  pane_takes_keys "$pane" || die "no key sent: pane $pane is in copy mode"
  pane_identity_matches "$pane" || die "no key sent: agent changed"
  tmux send-keys -t "$pane" "$name" || die "no key sent: tmux refused the key for $pane"
}

send_locked() {
  local pane=${1:-} text=${2:-} append=${3:-0} want box i rc reason cursor end_cursor last key
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
