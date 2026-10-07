# shellcheck shell=bash

pane_identity_matches() {
  [ -n "${PEON_EXPECTED_IDENTITY:-}" ] || return 0
  [ "$(tmux display-message -p -t "$1" '#{pid}:#{session_id}:#{pane_pid}' 2>/dev/null)" = "$PEON_EXPECTED_IDENTITY" ] && return 0
  echo 'peon-code: agent changed or closed; refresh before sending' >&2
  return 1
}

# One delivery owns the check/paste/submit sequence across all callers.
# Nonblocking directory locks work on macOS too.
# ponytail: a killed guard may leave a live tmux child; interrupted locks
# require manual cleanup after confirming all delivery processes stopped.
with_pane_delivery() (
  local pane=$1 identity key root lock holder connection
  shift
  identity=$(tmux display-message -p -t "$pane" '#{socket_path}:#{pane_id}' 2>/dev/null) || {
    echo "peon-code: cannot deliver to pane $pane: tmux cannot find it" >&2
    return 75
  }
  connection=${TMUX:-default}
  identity=${identity:-${connection%%,*}:$pane}
  key=$(printf '%s' "$identity" | cksum)
  key=${key%% *}
  [ "${PEON_DELIVERY_OWNER:-}" != "$$:$key" ] || { "$@"; exit $?; }
  root=/tmp/peon-code-delivery-$UID
  umask 077
  mkdir "$root" 2>/dev/null || true
  if [ ! -d "$root" ] || [ -L "$root" ] || [ ! -O "$root" ]; then
    echo 'peon-code: cannot create a private delivery lock directory' >&2; return 75
  fi
  lock=$root/$key
  if ! mkdir "$lock" 2>/dev/null; then
    echo "peon-code: another delivery owns $pane; retry after it finishes. Lock: $lock" >&2
    echo 'If interrupted, confirm all delivery processes stopped before removing that lock.' >&2
    return 75
  fi
  # $$ remains the invoking shell's PID in a Bash subshell. Ask its child
  # for the actual guard PID, so killing the caller cannot unlock a live guard.
  holder=$(exec sh -c 'echo "$PPID"')
  printf '%s\n' "$holder" >"$lock/owner" || { rmdir "$lock" 2>/dev/null || true; return 75; }
  trap 'rm -f "$lock/owner"; rmdir "$lock" 2>/dev/null || true' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP
  PEON_DELIVERY_OWNER=$$:$key
  "$@"
)
