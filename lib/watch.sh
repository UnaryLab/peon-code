# shellcheck shell=bash

# Context watcher: once a minute, read each agent pane's context size from
# the usage record its CLI writes to the transcript, and run compact on a pane
# that has reached the threshold. The transcript is the one source every CLI
# shares, so no pane screen is read. Only claude and codex are known to log
# usage; a pane of another CLI is named once as unwatched.

# The context size the pane's last turn was answered against, from the last
# usage record in its transcript. Empty when the CLI logs none, or the
# transcript has no turn yet.
context_tokens() {
  local bin=$1 file=$2 rec a b c
  case $bin in
    claude)
      # Each assistant message carries the API usage: the input plus both
      # cache fields is the full context of that request.
      rec=$(grep -o '"usage":{[^}]*}' "$file" 2>/dev/null | tail -n 1) || true
      [ -n "$rec" ] || return 0
      a=$(printf '%s' "$rec" | sed -n 's/.*"input_tokens":\([0-9]*\).*/\1/p')
      b=$(printf '%s' "$rec" | sed -n 's/.*"cache_creation_input_tokens":\([0-9]*\).*/\1/p')
      c=$(printf '%s' "$rec" | sed -n 's/.*"cache_read_input_tokens":\([0-9]*\).*/\1/p')
      [ -n "$a" ] || return 0
      echo $((a + ${b:-0} + ${c:-0})) ;;
    codex)
      # Each turn ends with a token_count event; last_token_usage.input_tokens
      # is the context of the last request.
      rec=$(grep -o '"last_token_usage":{"input_tokens":[0-9]*' "$file" 2>/dev/null | tail -n 1) || true
      [ -n "$rec" ] || return 0
      echo "${rec##*:}" ;;
  esac
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
# (a huge system prompt) is reported once instead of compacted every minute.
cmd_watch() {
  local session threshold panes id name bin file tokens
  local watched="" unwatched="" disarmed="" files=""
  session=$(session_name "${1:-}")
  threshold=${2:-270000}
  [[ $threshold =~ ^[0-9]+$ ]] || die "watch takes a number of tokens, got: $threshold"
  [ "$threshold" -gt 0 ] || return 0
  while tmux has-session -t "=$session" 2>/dev/null; do
    panes=$(list_agent_panes "$session") || true
    while read -r id name; do
      [ -n "$id" ] || continue
      bin=$(tmux show-options -pqv -t "$id" @peon_bin 2>/dev/null) || bin=""
      case $bin in
        claude|codex) ;;
        *)
          case " $unwatched " in *" $id "*) ;; *)
            unwatched="$unwatched $id"
            watch_note "$session" "$name (${bin:-unknown}) logs no context size; not watched" ;;
          esac
          continue ;;
      esac
      # The transcript appears after the first turn; look it up until found,
      # then keep the path. A pane id never repeats within a session.
      file=$(printf '%s\n' "$files" | sed -n "s|^$id |||p")
      if [ -z "$file" ]; then
        file=$(last_thread_file "agent $name of peon-code session $session," "$bin") || file=""
        [ -n "$file" ] || continue
        files="$files"$'\n'"$id $file"
      fi
      tokens=$(context_tokens "$bin" "$file")
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
      TMUX_PANE= "$SCRIPT_DIR/peon-code.sh" compact "$name" "$session" || true
    done <<<"$panes"
    sleep 60
  done
}
