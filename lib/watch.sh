# shellcheck shell=bash

# shellcheck source=lib/cli.sh
declare -F cli_call >/dev/null || source "$(dirname -- "${BASH_SOURCE[0]}")/cli.sh"

# Context watcher: scan every five seconds, read changed transcripts at most
# once a minute, and run compact on a pane that has reached the threshold.
# Context size comes from the usage record its CLI writes to the transcript.
# The transcript is the one source every CLI shares, so no pane screen is
# read. Only claude and codex are known to log usage; a pane of another CLI is
# named once as unwatched.
# Each full read stores nonempty Codex weekly limits in @peon_weekly and
# valid token totals in @peon_usage for the browser.

# The context size the pane's last turn was answered against, from the last
# usage record in its transcript. Empty when the CLI logs none, or the
# transcript has no turn yet.
context_tokens() {
  cli_call "$1" context_tokens "$2"
}

# Post a note on the session's status line, or on stderr when no client shows
# the session.
watch_note() {
  local session=$1 note=$2 client
  client=$(tmux list-clients -t "=$session" -F '#{client_name}' 2>/dev/null | head -1) || client=""
  if [ -n "$client" ]; then
    tmux display-message -d 10000 -c "$client" -- "${note//#/##}"
  else
    echo "peon-code: $note" >&2
  fi
}

# peon-code watch [<session>] [<tokens>]: loop until the session is gone.
# A pane fires once per crossing: after a compact it is disarmed until its
# reading drops below the threshold again, so a floor above the threshold
# (a huge system prompt) is reported once rather than on each changed reading.
cmd_watch() {
  local session threshold panes id name bin file tokens weekly usage owner pid_file
  local now size last_size last_read last_lookup min=${PEON_WATCH_MIN:-60}
  local unwatched="" disarmed="" files="" reads="" lookups=""
  session=$(session_name "${1:-}")
  threshold=${2:-250000}
  [[ $threshold =~ ^[0-9]+$ ]] || die "watch takes a number of tokens, got: $threshold"
  [ "$threshold" -gt 0 ] || return 0
  pid_file="/tmp/peon-code-watch-$UID/$session.pid"
  (umask 077; mkdir -p "/tmp/peon-code-watch-$UID"; printf '%s\n' "$$" >"$pid_file") || true
  # A resume recreates the session under the same name, so an older watcher
  # can outlive its session's kill. The newest watcher owns the session; an
  # older one exits on its next tick, up to one tick late.
  tmux set-option -t "=$session:" @peon_watch_pid "$$" 2>/dev/null || true
  while tmux has-session -t "=$session" 2>/dev/null; do
    owner=$(tmux show-options -qv -t "=$session:" @peon_watch_pid 2>/dev/null) || owner=""
    [ -z "$owner" ] || [ "$owner" = "$$" ] || break
    panes=$(list_agent_panes "$session") || true
    while read -r id name; do
      [ -n "$id" ] || continue
      bin=$(tmux show-options -pqv -t "$id" @peon_bin 2>/dev/null) || bin=""
      if ! declare -F -- "${bin}_context_tokens" >/dev/null ||
        ! cli_call "$bin" context_tokens; then
        case " $unwatched " in *" $id "*) ;; *)
          unwatched="$unwatched $id"
          watch_note "$session" "$name (${bin:-unknown}) logs no context size; not watched" ;;
        esac
        continue
      fi
      # Retry a missing transcript only at the read interval, then keep its
      # path. A pane id never repeats within a session.
      file=$(printf '%s\n' "$files" | sed -n "s|^$id ||p")
      if [ -z "$file" ]; then
        now=$(date +%s)
        last_lookup=$(printf '%s\n' "$lookups" | sed -n "s|^$id ||p")
        if [ -n "$last_lookup" ] && [ "$((now - last_lookup))" -lt "$min" ]; then
          continue
        fi
        file=$(last_thread_file "agent $name of peon-code session $session," "$bin") || file=""
        lookups=$(printf '%s\n' "$lookups" | sed "/^$id /d")
        lookups="$lookups"$'\n'"$id $now"
        [ -n "$file" ] || continue
        files="$files"$'\n'"$id $file"
      fi
      size=$(wc -c 2>/dev/null <"$file") || continue
      now=$(date +%s)
      read -r last_size last_read <<<"$(printf '%s\n' "$reads" | sed -n "s|^$id ||p")"
      if [ -n "$last_read" ] && { [ "$size" -eq "$last_size" ] || [ "$((now - last_read))" -lt "$min" ]; }; then
        continue
      fi
      weekly=$(cli_call "$bin" weekly_limit "$file") || weekly=""
      [ -z "$weekly" ] || tmux set -pt "$id" @peon_weekly "$weekly" 2>/dev/null || true
      usage=$(cli_call "$bin" usage_tokens "$file") || usage=""
      if [[ $usage =~ ^[0-9]+\ [0-9]+\ [0-9]+\ [0-9]+$ ]]; then
        tmux set -pt "$id" @peon_usage "$usage" 2>/dev/null || true
      fi
      tokens=$(context_tokens "$bin" "$file")
      now=$(date +%s)
      reads=$(printf '%s\n' "$reads" | sed "/^$id /d")
      reads="$reads"$'\n'"$id $size $now"
      [ -n "$tokens" ] || continue
      if [ "$tokens" -lt "$threshold" ]; then
        disarmed=${disarmed// $id / }
        continue
      fi
      case " $disarmed " in *" $id "*) continue ;; esac
      disarmed="$disarmed $id "
      watch_note "$session" "$name at $tokens tokens; compacting"
      # Compact skips a busy pane with a note and leaves the brief unsent
      # when compaction outlasts its wait; this pane is retried on the next
      # crossing. The pane variable is cleared so compact does not take
      # the watcher's own pane for a target.
      TMUX_PANE='' "$SCRIPT_DIR/peon-code.sh" compact "$name" "$session" || true
    done <<<"$panes"
    sleep "${PEON_WATCH_TICK:-5}"
  done
  if [ "$(cat "$pid_file" 2>/dev/null)" = "$$" ]; then
    rm -f "$pid_file"
  fi
}
