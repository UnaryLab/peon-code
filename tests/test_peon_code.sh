#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

# Syntax-check the scripts under test before running any case file.
for script in "$ROOT/peon-code.sh" "$ROOT/peon-code-web.sh" "$ROOT/install.sh" "$ROOT"/lib/*.sh; do
  bash -n "$script"
done

test_terminal_mouse_defaults() (
  local socket="peon-terminal-mouse-test-$$" session=terminal-mouse-test table key binding
  # shellcheck source=lib/session.sh
  source "$ROOT/lib/session.sh"
  tmux() { command tmux -L "$socket" -f /dev/null "$@"; }
  trap 'tmux kill-session -t "=$session" 2>/dev/null || true' EXIT
  create_agent_session "$session" 1 0
  tmux set-option -g mouse on
  (goto_session "$session") </dev/null >/dev/null
  [ -z "$(tmux show-options -qv -t "$session" mouse)" ] || {
    echo 'FAIL: new session overrides the tmux mouse option' >&2
    exit 1
  }
  [ "$(tmux show-options -gv mouse)" = on ] || {
    echo 'FAIL: new session changed the global tmux mouse option' >&2
    exit 1
  }
  for table in copy-mode copy-mode-vi; do
    for key in MouseDown3Pane M-e; do
      binding=$(tmux list-keys -T "$table" "$key" 2>/dev/null || true)
      case $binding in
        *peon_script*) echo "FAIL: $table $key uses peon_script" >&2; exit 1 ;;
      esac
    done
  done
)
test_terminal_mouse_defaults

# Each tests/cases/*.sh file is a standalone run of one topic group. Run them
# all, keep going past a failure, and pass only if every one passed.
status=0
for case_file in "$ROOT"/tests/cases/*.sh; do
  if ! bash "$case_file"; then
    echo "FAIL: $case_file" >&2
    status=1
  fi
done
[ "$status" -eq 0 ] || exit 1
echo "tests: PASS"
