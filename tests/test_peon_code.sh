#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

# Syntax-check the scripts under test before running any case file.
for script in "$ROOT/peon-code.sh" "$ROOT/peon-code-web.sh" "$ROOT/install.sh" "$ROOT"/lib/*.sh "$ROOT"/lib/cli/*.sh; do
  bash -n "$script"
done

test_cli_provider_functions() (
  local provider bin concern marker char
  # shellcheck source=lib/cli.sh
  source "$ROOT/lib/cli.sh"
  for provider in "$ROOT"/lib/cli/*.sh; do
    bin=${provider##*/}
    bin=${bin%.sh}
    for concern in launch_command trust_project resume_dir resume_id context_tokens paste_placeholder prompt_marker; do
      declare -F -- "${bin}_$concern" >/dev/null || {
        echo "FAIL: $provider lacks ${bin}_$concern" >&2
        exit 1
      }
    done
    marker=$(cli_call "$bin" prompt_marker)
    for char in '.' '[' ']' '(' ')' '{' '}' '*' '+' '?' '^' '$' "\\" '|'; do
      case $marker in
        *"$char"*) echo "FAIL: $provider prompt marker contains $char" >&2; exit 1 ;;
      esac
    done
  done
)
test_cli_provider_functions

test_unknown_cli_launch() (
  # shellcheck source=lib/cli.sh
  source "$ROOT/lib/cli.sh"
  [ "$(cli_call ./unknown-agent launch_command ./unknown-agent ' --flag value' thread '"prompt text"' 0)" = './unknown-agent --flag value "prompt text"' ] || {
    echo 'FAIL: unknown CLI did not launch with a positional prompt' >&2
    exit 1
  }
)
test_unknown_cli_launch

test_cli_provider_parsers() (
  # shellcheck source=lib/input.sh
  source "$ROOT/lib/input.sh"
  # A two-byte marker checks that the parser uses the provider length.
  # shellcheck disable=SC2317 # cli_call invokes these functions by name.
  extra_prompt_marker() { printf '\302\273'; }
  # shellcheck disable=SC2317 # cli_call invokes these functions by name.
  extra_paste_placeholder() { printf '%s\n' '^\[Extra paste\]$'; }
  CLI_PROVIDERS+=(extra)
  CLI_PROMPT_MARKERS="$CLI_PROMPT_MARKERS|$(extra_prompt_marker)"
  CLI_PASTE_PLACEHOLDERS+=("$(extra_paste_placeholder)")
  # shellcheck disable=SC2317 # A cached parser must not query a provider again.
  extra_prompt_marker() { echo 'FAIL: prompt marker read after load' >&2; return 1; }
  # shellcheck disable=SC2317 # A cached parser must not query a provider again.
  extra_paste_placeholder() { echo 'FAIL: paste placeholder read after load' >&2; return 1; }
  # shellcheck source=lib/cli.sh
  source "$ROOT/lib/cli.sh"
  box_is_paste_placeholder '[Extra paste]' || exit 1
  box_holds_message '[Extra paste]' 'draft text' || exit 1
  pane_has_menu '» 1. Yes' 0 || exit 1
  [ "$(pane_free_text_number '» 2. Type something.')" = 2 ] || exit 1
  [ "$(printf '\033[2m» hint\033[0m typed\n' | strip_styles 1)" = '»      typed' ] || exit 1
  tmux() {
    case $1 in
      display) printf '0\n' ;;
      capture-pane) printf '» draft\n' ;;
    esac
  }
  [ "$(pane_box_text %9)" = draft ] || exit 1
  cli_call claude context_tokens || exit 1
  if cli_call copilot context_tokens; then exit 1; fi
  [ -z "$(cli_call copilot context_tokens unused.jsonl)" ] || exit 1
)
test_cli_provider_parsers

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
