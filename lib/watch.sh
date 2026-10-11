# shellcheck shell=bash

# shellcheck source=lib/cli.sh
declare -F cli_call >/dev/null || source "$(dirname -- "${BASH_SOURCE[0]}")/cli.sh"

# Scan every five seconds, re-read changed transcripts on one shared minute beat,
# and compact a pane that has reached the threshold.
# Context size comes from the usage record its CLI writes to the transcript.
# Only claude and codex are known to log usage; another CLI is named once
# as unwatched. Restart mode also reads pane screens: after an agent was seen,
# two shell scans with unchanged text trigger a resume or a fresh launch.
# Each pane gets at most three crash restart attempts in a rolling hour.
# Each full read stores nonempty Codex weekly limits in @peon_weekly and
# valid token totals for the thread and its children in @peon_usage for the browser.

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

# Clear partial shell input. Keys typed during the roughly one second between
# paste and Enter can still join the restart command.
watch_launch_locked() {
  local pending=${3:-} owner=${4:-} claimed=${5:-} current command
  command=$(tmux display -pt "$1" '#{pane_current_command}' 2>/dev/null) || return 1
  case $command in sh|bash|zsh|fish|dash|ksh|systemd-run) ;; *) return 1 ;; esac
  current=$(tmux show-options -pqv -t "$1" @peon_swap_pending 2>/dev/null) || current=""
  if [ -n "$pending" ]; then
    [ "$current" = "$pending" ] &&
      [ "$(tmux show-options -pqv -t "$1" @peon_swap_owner 2>/dev/null)" = "$owner" ] &&
      [ "$(tmux display-message -p -t "$1" '#{pid}:#{session_id}:#{pane_pid}' 2>/dev/null)" = "$(tmux show-options -pqv -t "$1" @peon_swap_identity 2>/dev/null)" ] || return 1
    tmux set -pt "$1" @peon_swap_pending "$claimed" || return 1
    if declare -F swap_discard_backup_locked >/dev/null; then swap_discard_backup_locked "$1" || return 1; fi
  else
    [ -z "$current" ] || return 1
  fi
  tmux send-keys -t "$1" C-u || return 1
  launch_command_locked "$1" "$2"
}

watch_swap_finish_locked() {
  local id=$1 command=$2 owner=$3 identity=$4 result=$5 claimed=$6 note
  [ "$(tmux display-message -p -t "$id" '#{pid}:#{session_id}:#{pane_pid}' 2>/dev/null)" = "$identity" ] &&
    [ "$(tmux show-options -pqv -t "$id" @peon_swap_identity 2>/dev/null)" = "$identity" ] &&
    [ "$(tmux show-options -pqv -t "$id" @peon_swap_owner 2>/dev/null)" = "$owner" ] &&
    [ "$(tmux show-options -pqv -t "$id" @peon_swap_pending 2>/dev/null)" = "$claimed" ] || return 1
  if [ "$result" = 0 ]; then note="done $command"
  else note='failed: the swapped agent did not become ready with its brief'; fi
  tmux set -pt "$id" @peon_swap "$note" || return 1
  tmux set -pu -t "$id" @peon_swap_pending || return 1
  tmux set -pu -t "$id" @peon_swap_pid || return 1
}

watch_swap_reap_locked() {
  local id=$1 pending claim pid identity owner watcher job args
  pending=$(tmux show-options -pqv -t "$id" @peon_swap_pending 2>/dev/null) || return 1
  case $pending in waiting\ *|running\ *) ;; *) return 1 ;; esac
  claim=${pending#* }
  pid=${claim%%:*}
  case $pid in ''|*[!0-9]*) return 1 ;; esac
  if kill -0 "$pid" 2>/dev/null; then
    watcher=$(tmux show-options -qv -t "=$(tmux display -pt "$id" '#{session_name}'):" @peon_watch_pid 2>/dev/null) || watcher=""
    [ "$pid" != "$watcher" ] || return 1
    job=$(tmux show-options -pqv -t "$id" @peon_swap_pid 2>/dev/null) || job=""
    owner=$(tmux show-options -pqv -t "$id" @peon_swap_owner 2>/dev/null) || owner=""
    args=$(ps -ww -p "$pid" -o args= 2>/dev/null) || args=""
    case $pending in running\ *) job=$pid ;; esac
    if [ "$pid" = "$job" ] && [ -n "$owner" ]; then
      case $args in *"$owner"*) return 1 ;; esac
    fi
  fi
  identity=$(tmux show-options -pqv -t "$id" @peon_swap_identity 2>/dev/null) || return 1
  owner=$(tmux show-options -pqv -t "$id" @peon_swap_owner 2>/dev/null) || return 1
  [ -n "$identity" ] &&
    [ "$(tmux display-message -p -t "$id" '#{pid}:#{session_id}:#{pane_pid}' 2>/dev/null)" = "$identity" ] &&
    [ "$(tmux show-options -pqv -t "$id" @peon_swap_owner 2>/dev/null)" = "$owner" ] || return 1
  case $pending in
    waiting\ *)
      if declare -F swap_abort_locked >/dev/null; then
        local PEON_EXPECTED_IDENTITY=$identity SWAP_OWNER=$owner
        swap_abort_locked "$id" || return 1
      fi ;;
  esac
  tmux set -pt "$id" @peon_swap 'failed: swap restart job stopped' || return 1
  tmux set -pu -t "$id" @peon_swap_pending || return 1
  tmux set -pu -t "$id" @peon_swap_pid
}

watch_restart() {
  local pending owner identity claimed command rc=0
  pending=$(tmux show-options -pqv -t "$2" @peon_swap_pending 2>/dev/null) || pending=""
  case $pending in running*) with_pane_delivery "$2" watch_swap_reap_locked "$2" || true; return 1 ;; esac
  owner=$(tmux show-options -pqv -t "$2" @peon_swap_owner 2>/dev/null) || owner=""
  identity=$(tmux display-message -p -t "$2" '#{pid}:#{session_id}:#{pane_pid}' 2>/dev/null) || identity=""
  command=${pending#* * }
  claimed="running $(exec sh -c 'echo "$PPID"'):$(date +%s):$RANDOM $command"
  watch_restart_agent "$@" || rc=$?
  if [ -n "$pending" ]; then
    with_pane_delivery "$2" watch_swap_finish_locked "$2" "$command" "$owner" "$identity" "$rc" "$claimed" || return 1
    if [ "$rc" = 0 ]; then watch_note "$1" "$3 swapped to $command"
    else watch_note "$1" "$3 could not restart after its swap"; fi
  fi
  return "$rc"
}

# Provider startup hooks read these locals through Bash's dynamic scope.
# shellcheck disable=SC2034
watch_restart_agent() {
  local session=$1 id=$2 name=$3 ref=$4 launch=$5 bin fresh file rid="" args brief_file mode=fresh
  local i=0 RID="" BRIEF="" PASTE_RC=0 NAMES=("$name") PANE_IDS=("$id")
  bin=$(tmux show-options -pqv -t "$id" @peon_bin 2>/dev/null) || return 1
  [ -n "$bin" ] || return 1
  fresh=$(tmux show-options -pqv -t "$id" @peon_fresh 2>/dev/null) || fresh=""
  if [ "$fresh" != 1 ]; then
    file=$(last_thread_file "agent $name of peon-code session $session," "$bin" "$ref") || file=""
    if [ -n "$file" ]; then
      rid=$(cli_call "$bin" resume_id "$file") || rid=""
    fi
  fi
  if [ -n "$rid" ] && args=$(cli_call "$bin" resume_args "$(printf %q "$rid")") && [ -n "$args" ]; then
    launch="$bin$args${launch#"$bin"}"
    RID=$rid
    mode=resume
  fi
  watch_note "$session" "$name died; restarting with $mode"
  with_pane_delivery "$id" watch_launch_locked "$id" "$launch" "${pending:-}" "${owner:-}" "${claimed:-}" || return 1
  wait_agent_ready "$id" || return 1
  brief_file=$(tmux show-options -pqv -t "$id" @peon_brief 2>/dev/null) || brief_file=""
  [ -z "$brief_file" ] || BRIEF=$(cat "$brief_file" 2>/dev/null) || BRIEF=""
  cli_call "$bin" brief_after_start || return 1
  [ "$PASTE_RC" -eq 0 ] || return 1
  [ "$fresh" != 1 ] || tmux set -pt "$id" @peon_fresh 0
}

# peon-code watch [<session>] [<tokens>]: loop until the session is gone.
# Restart mode also runs with zero tokens; initial shells are left alone.
# A dead pane needs two unchanged shell scans after a non-shell scan, then
# resumes its thread when supported, or starts fresh, at most three crashes per hour.
# A pane fires once per crossing: after a compact it is disarmed until its
# reading drops below the threshold again, so a floor above the threshold
# (a huge system prompt) is reported once rather than on each changed reading.
cmd_watch() {
  local session threshold panes id name bin file new_file tokens weekly usage owner pid_file
  local now size last_size last_lookup min=${PEON_WATCH_MIN:-60}
  local last_beat=0 beat_time
  local created stamp ref exit_trap cleanup restart current state count launch capture hash last_hash pending
  local unwatched="" disarmed="" files="" reads="" lookups=""
  local states="" restarts="" capped=""
  session=$(session_name "${1:-}")
  threshold=${2:-250000}
  [[ $threshold =~ ^[0-9]+$ ]] || die "watch takes a number of tokens, got: $threshold"
  restart=$(tmux show-options -qv -t "=$session:" @peon_restart 2>/dev/null) || restart=""
  [ "$threshold" -gt 0 ] || [ "$restart" = 1 ] || return 0
  created=$(tmux display -p -t "=$session:" '#{session_created}' 2>/dev/null) || return 0
  case $created in ''|*[!0-9]*) return 0 ;; esac
  # BSD and GNU date use different flags to format an epoch.
  stamp=$(date -u -r "$created" +%Y%m%d%H%M.%S 2>/dev/null) ||
    stamp=$(date -u -d "@$created" +%Y%m%d%H%M.%S) || return 1
  ref=$(mktemp "${TMPDIR:-/tmp}/peon-code-watch.XXXXXX") || return 1
  exit_trap=$(trap -p EXIT)
  cleanup=$(printf 'rm -f -- %q;' "$ref")
  if [ -n "$exit_trap" ]; then
    eval "set -- ${exit_trap#trap -- }"
    cleanup="$cleanup $1"
  fi
  # shellcheck disable=SC2064 # Bind the reference path before local variables leave scope.
  trap "$cleanup" EXIT
  trap 'exit 143' TERM
  TZ=UTC0 touch -t "$stamp" "$ref" || return 1
  pid_file="/tmp/peon-code-watch-$UID/$session.pid"
  (umask 077; mkdir -p "/tmp/peon-code-watch-$UID"; printf '%s\n' "$$" >"$pid_file") || true
  # A resume recreates the session under the same name, so an older watcher
  # can outlive its session's kill. The newest watcher owns the session; an
  # older one exits on its next tick, up to one tick late.
  tmux set-option -t "=$session:" @peon_watch_pid "$$" 2>/dev/null || true
  while tmux has-session -t "=$session" 2>/dev/null; do
    owner=$(tmux show-options -qv -t "=$session:" @peon_watch_pid 2>/dev/null) || owner=""
    [ -z "$owner" ] || [ "$owner" = "$$" ] || break
    if [ "$restart" = 1 ]; then
      panes=$(tmux list-panes -s -t "=$session" -F '#{pane_id} #{@peon_name}' 2>/dev/null) || panes=""
    else
      panes=$(list_agent_panes "$session") || true
    fi
    beat_time=$(date +%s)
    while read -r id name; do
      [ -n "$id" ] || continue
      [ -n "$name" ] || continue
      bin=$(tmux show-options -pqv -t "$id" @peon_bin 2>/dev/null) || bin=""
      if [ "$restart" = 1 ]; then
        pending=$(tmux show-options -pqv -t "$id" @peon_swap_pending 2>/dev/null) || pending=""
        case $pending in running*) with_pane_delivery "$id" watch_swap_reap_locked "$id" || true; continue ;; esac
        case $pending in waiting\ *)
          if with_pane_delivery "$id" watch_swap_reap_locked "$id"; then continue; fi ;;
        esac
        current=$(tmux display -pt "$id" '#{pane_current_command}' 2>/dev/null) || current=""
        read -r state last_hash <<<"$(printf '%s\n' "$states" | sed -n "s|^$id ||p")"
        hash=""
        case $current in
          '') [ -n "$state" ] || continue; state=0 ;;
          sh|bash|zsh|fish|dash|ksh|systemd-run)
            if [ -z "$state" ]; then
              [ -n "$pending" ] || continue
              state=0
            fi
            if capture=$(tmux capture-pane -pt "$id" 2>/dev/null); then
              hash=$(printf '%s' "$capture" | cksum)
              [ "$hash" = "$last_hash" ] || state=0
              state=$((state + 1))
            else
              state=0
              current=""
            fi ;;
          *) state=0 ;;
        esac
        states=$(printf '%s\n' "$states" | sed "/^$id /d")
        states="$states"$'\n'"$id $state $hash"
        [ -n "$current" ] || continue
        if [ "$state" -ge 2 ]; then
          now=$(date +%s)
          restarts=$(printf '%s\n' "$restarts" | awk -v id="$id" -v now="$now" '$1 != id || now - $2 < 3600')
          count=$(printf '%s\n' "$restarts" | awk -v id="$id" '$1 == id { n++ } END { print n+0 }')
          if [ -z "$pending" ] && [ "$count" -ge 3 ]; then
            case " $capped " in *" $id "*) ;; *)
              capped="$capped $id "
              watch_note "$session" "$name died 3 times in an hour; left at shell" ;;
            esac
            continue
          fi
          launch=$(tmux show-options -pqv -t "$id" @peon_launch 2>/dev/null) || launch=""
          [ -n "$launch" ] || continue
          [ -n "$pending" ] || restarts="$restarts"$'\n'"$id $now"
          capped=${capped// $id / }
          watch_restart "$session" "$id" "$name" "$ref" "$launch" || true
          states=$(printf '%s\n' "$states" | sed "/^$id /d")
          states="$states"$'\n'"$id 0"
          files=$(printf '%s\n' "$files" | sed "/^$id /d")
          reads=$(printf '%s\n' "$reads" | sed "/^$id /d")
          lookups=$(printf '%s\n' "$lookups" | sed "/^$id /d")
          disarmed=${disarmed// $id / }
          continue
        fi
        [ "$state" -eq 0 ] || continue
      fi
      [ "$threshold" -gt 0 ] || continue
      if ! declare -F -- "${bin}_context_tokens" >/dev/null ||
        ! cli_call "$bin" context_tokens; then
        case " $unwatched " in *" $id "*) ;; *)
          unwatched="$unwatched $id"
          watch_note "$session" "$name (${bin:-unknown}) logs no context size; not watched" ;;
        esac
        continue
      fi
      # Retry missing paths every scan; refresh cached paths at their lookup interval.
      # A pane id never repeats within a session.
      file=$(printf '%s\n' "$files" | sed -n "s|^$id ||p")
      now=$(date +%s)
      last_lookup=$(printf '%s\n' "$lookups" | sed -n "s|^$id ||p")
      if [ -z "$last_lookup" ] || [ "$((now - last_lookup))" -ge "$min" ]; then
        new_file=$(last_thread_file "agent $name of peon-code session $session," "$bin" "$ref") || new_file=""
        lookups=$(printf '%s\n' "$lookups" | sed "/^$id /d")
        [ -z "$new_file" ] || lookups="$lookups"$'\n'"$id $now"
        if [ "$new_file" != "$file" ]; then
          file=$new_file
          files=$(printf '%s\n' "$files" | sed "/^$id /d")
          files="$files"$'\n'"$id $file"
          reads=$(printf '%s\n' "$reads" | sed "/^$id /d")
        fi
      fi
      [ -n "$file" ] || continue
      size=$(wc -c 2>/dev/null <"$file") || continue
      read -r last_size <<<"$(printf '%s\n' "$reads" | sed -n "s|^$id ||p")"
      if [ -n "$last_size" ] && { [ "$size" -eq "$last_size" ] || [ "$((beat_time - last_beat))" -lt "$min" ]; }; then
        continue
      fi
      weekly=$(cli_call "$bin" weekly_limit "$file") || weekly=""
      [ -z "$weekly" ] || tmux set -pt "$id" @peon_weekly "$weekly" 2>/dev/null || true
      usage=$(cli_usage_sum "$bin" "$file") || usage=""
      if [[ $usage =~ ^[0-9]+\ [0-9]+\ [0-9]+\ [0-9]+$ ]]; then
        tmux set -pt "$id" @peon_usage "$usage" 2>/dev/null || true
      fi
      tokens=$(context_tokens "$bin" "$file")
      # Retry every tick until the transcript has context tokens or usage.
      [ -n "$tokens" ] || [ -n "$usage" ] || continue
      reads=$(printf '%s\n' "$reads" | sed "/^$id /d")
      reads="$reads"$'\n'"$id $size"
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
    if [ "$((beat_time - last_beat))" -ge "$min" ]; then last_beat=$beat_time; fi
    sleep "${PEON_WATCH_TICK:-5}"
  done
  if [ "$(cat "$pid_file" 2>/dev/null)" = "$$" ]; then
    rm -f "$pid_file"
  fi
}
