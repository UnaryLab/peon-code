#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

# Syntax-check the scripts under test before running any case file.
for script in "$ROOT/peon-code.sh" "$ROOT/peon-code-web.sh" "$ROOT/install.sh" "$ROOT/.githooks/pre-commit" "$ROOT"/lib/*.sh "$ROOT"/lib/cli/*.sh; do
  bash -n "$script"
done

test_cli_provider_functions() (
  local provider bin concern marker char
  # shellcheck source=lib/cli.sh
  source "$ROOT/lib/cli.sh"
  for provider in "$ROOT"/lib/cli/*.sh; do
    bin=${provider##*/}
    bin=${bin%.sh}
    for concern in launch_command trust_project resume_dir resume_id context_tokens usage_tokens weekly_limit paste_placeholder prompt_marker; do
      case $concern:$bin in
        usage_tokens:claude|usage_tokens:codex) ;;
        usage_tokens:*) continue ;;
        weekly_limit:codex) ;;
        weekly_limit:*) continue ;;
      esac
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

# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"

test_version() {
  local missing="$TEST_DIR/version-no-file" option
  cmp "$ROOT/VERSION" <("$ROOT/peon-code.sh" --version) || fail '--version differs from VERSION'
  "$ROOT/peon-code.sh" --help >"$TEST_DIR/version-help"
  [ "$(head -1 "$TEST_DIR/version-help")" = "peon-code $(cat "$ROOT/VERSION")" ] || fail 'help does not begin with the version'
  mkdir -p "$missing"
  cp "$ROOT/peon-code.sh" "$missing/"
  cp -R "$ROOT/lib" "$missing/"
  for option in -h --help --version; do
    "$missing/peon-code.sh" "$option" >"$TEST_DIR/version-missing.out" 2>"$TEST_DIR/version-missing.err" ||
      fail "$option failed without VERSION"
    case $option in
      --version) [ "$(cat "$TEST_DIR/version-missing.out")" = unknown ] || fail 'missing VERSION did not report unknown' ;;
      *) [ "$(head -1 "$TEST_DIR/version-missing.out")" = 'peon-code unknown' ] || fail 'missing VERSION broke the help header' ;;
    esac
    [ ! -s "$TEST_DIR/version-missing.err" ] || fail "$option wrote an error without VERSION"
  done
}
test_version

test_version_hook() (
  local repo="$TEST_DIR/version-repo" missing="$TEST_DIR/version-missing" version
  git init -q -b main "$repo"
  printf '0.1.0\n' >"$repo/VERSION"
  (cd "$repo" && "$ROOT/.githooks/pre-commit") || fail 'version hook failed'
  [ "$(cat "$repo/VERSION")" = 0.1.1 ] || fail 'version hook did not increment the patch'
  [ "$(git -C "$repo" show :VERSION)" = 0.1.1 ] || fail 'version hook did not stage VERSION'
  for version in 'bad' '-1.1.0' '0.1.00' '0.1.0.1'; do
    printf '%s\n' "$version" >"$repo/VERSION"
    if (cd "$repo" && "$ROOT/.githooks/pre-commit") 2>"$TEST_DIR/version-hook.err"; then
      fail "version hook accepted $version"
    fi
    [ "$(cat "$repo/VERSION")" = "$version" ] || fail 'invalid VERSION was changed'
    [ "$(git -C "$repo" show :VERSION)" = 0.1.1 ] || fail 'invalid VERSION was staged'
  done
  mkdir -p "$missing"
  (cd "$missing" && "$ROOT/.githooks/pre-commit") || fail 'version hook failed without VERSION'
  [ ! -e "$missing/VERSION" ] || fail 'version hook created a missing VERSION'
)
test_version_hook

write_usage_fixtures() {
  cat >"$TEST_DIR/claude.jsonl" <<'CLAUDE'
{"type":"assistant","requestId":"r1","message":{"usage":{"input_tokens":1,"cache_read_input_tokens":100,"cache_creation_input_tokens":20,"output_tokens":1}}}
{"type":"assistant","requestId":"r1","message":{"usage":{"input_tokens":2,"cache_read_input_tokens":100,"cache_creation_input_tokens":20,"output_tokens":2}}}
{"type":"assistant","requestId":"r1","message":{"usage":{"input_tokens":10,"cache_read_input_tokens":100,"cache_creation_input_tokens":20,"cache_creation":{"ephemeral_5m_input_tokens":20,"ephemeral_1h_input_tokens":0},"output_tokens":9}}}
{"type":"assistant","message":{"usage":{"output_tokens":7,"cache_creation_input_tokens":6,"input_tokens":4,"cache_read_input_tokens":30}},"requestId":"r2"}
CLAUDE
  cat >"$TEST_DIR/codex.jsonl" <<'CODEX'
{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":30,"output_tokens":20,"reasoning_output_tokens":5,"total_tokens":999}}}}
{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":200,"cached_input_tokens":120,"output_tokens":50,"reasoning_output_tokens":10,"total_tokens":999}}}}
CODEX
}

test_cli_usage_tokens() (
  local actual
  # shellcheck source=lib/cli.sh
  source "$ROOT/lib/cli.sh"
  write_usage_fixtures
  [ "$(cli_call claude usage_tokens "$TEST_DIR/claude.jsonl")" = '14 130 26 16' ] || fail 'Claude usage counts repeated request IDs'
  [ "$(cli_call codex usage_tokens "$TEST_DIR/codex.jsonl")" = '80 120 0 50' ] || fail 'Codex usage does not separate cached input from the last cumulative record'
  printf '%s\n' '{"payload":{"info":{"total_token_usage":{"input_tokens":80,"cached_input_tokens":120,"output_tokens":5}}}}' >"$TEST_DIR/codex-invalid.jsonl"
  [ -z "$(cli_call codex usage_tokens "$TEST_DIR/codex-invalid.jsonl")" ] || fail 'Codex usage accepts cached input above total input'
  for actual in claude codex; do
    cli_call "$actual" usage_tokens || fail "$actual usage probe failed"
    [ -z "$(cli_call "$actual" usage_tokens "$TEST_DIR/missing.jsonl")" ] || fail "$actual reports usage without a transcript"
  done
  if actual=$(cli_call copilot usage_tokens "$TEST_DIR/claude.jsonl"); then
    fail 'unsupported CLI accepted usage_tokens with a file'
  fi
  [ -z "$actual" ] || fail 'unsupported CLI emitted token usage'
)
test_cli_usage_tokens

test_cli_weekly_limit() (
  local file="$TEST_DIR/weekly.jsonl" bin actual
  # shellcheck source=lib/cli.sh
  source "$ROOT/lib/cli.sh"
  cli_call codex weekly_limit || fail 'Codex weekly limit probe failed'
  [ -z "$(cli_call codex weekly_limit "$TEST_DIR/missing.jsonl")" ] || fail 'missing transcript reports a weekly limit'
  printf '%s\n' '{"payload":{"type":"token_count","rate_limits":{"primary":{"window_minutes":10080,"used_percent":25.26,"resets_at":1700000000},"secondary":{"window_minutes":300,"used_percent":99,"resets_at":1}}}}' >"$file"
  [ "$(cli_call codex weekly_limit "$file")" = '25.3 1700000000' ] || fail 'primary weekly limit was not read'
  printf '%s\n' '{"payload": {"type": "token_count", "rate_limits": {"primary": {"window_minutes": 300, "used_percent": 1, "resets_at": 1}, "secondary": {"resets_at": 1700000001, "used_percent": 40, "window_minutes": 10080}}}}' >>"$file"
  [ "$(cli_call codex weekly_limit "$file")" = '40.0 1700000001' ] || fail 'latest secondary weekly limit was not read'
  printf '%s\n' '{"payload":{"type":"other","rate_limits":{"primary":{"window_minutes":10080,"used_percent":90,"resets_at":1}}}}' >>"$file"
  [ "$(cli_call codex weekly_limit "$file")" = '40.0 1700000001' ] || fail 'an unrelated event replaced the weekly limit'
  printf '%s\n' '{"payload":{"type":"token_count","rate_limits":{"primary":{"window_minutes":10080,"used_percent":"bad","resets_at":1700000000}}}}' >>"$file"
  [ -z "$(cli_call codex weekly_limit "$file")" ] || fail 'invalid latest weekly limit reused an old record'
  printf '%s\n' '{"payload":{"type":"token_count","rate_limits":{"primary":{"window_minutes":300,"used_percent":1,"resets_at":1}}}}' >"$file"
  [ -z "$(cli_call codex weekly_limit "$file")" ] || fail 'a short window reports a weekly limit'
  printf '%s\n' '{"payload":{"type":"token_count","rate_limits":{"primary":{"window_minutes":10080,"used_percent":1,"resets_at":1.5}}}}' >"$file"
  [ -z "$(cli_call codex weekly_limit "$file")" ] || fail 'a fractional reset reports a weekly limit'
  printf '%s\n' '{"payload":{"type":"token_count","rate_limits":{"primary":{"window_minutes":10080,"used_percent":104.6,"resets_at":1700000000}}}}' >"$file"
  [ "$(cli_call codex weekly_limit "$file")" = '100.0 1700000000' ] || fail 'Codex weekly limit exceeds 100 percent'
  : >"$file"
  [ -z "$(cli_call codex weekly_limit "$file")" ] || fail 'empty transcript reports a weekly limit'
  for bin in claude copilot gemini grok qwen unknown; do
    if actual=$(cli_call "$bin" weekly_limit "$file"); then fail "$bin accepts weekly_limit"; fi
    [ -z "$actual" ] || fail "$bin emits an unsupported weekly limit"
  done
)
test_cli_weekly_limit

test_weekly_watch() (
  local session="peon-weekly-watch-$$" ticks=0 transcript="$TEST_DIR/watch-weekly.jsonl" log="$TEST_DIR/watch-weekly.log"
  # shellcheck source=lib/watch.sh
  source "$ROOT/lib/watch.sh"
  printf '%s\n' '{"payload":{"type":"token_count","rate_limits":{"primary":{"window_minutes":10080,"used_percent":22,"resets_at":1700000000}}}}' >"$transcript"
  tmux() {
    case $1 in
      has-session)
        ticks=$((ticks + 1))
        case $ticks in 3) printf '\n' >>"$transcript" ;; esac
        [ "$ticks" -le 3 ] ;;
      show-options) case $* in *@peon_bin*) echo codex ;; esac ;;
      set) printf '%s\n' "$*" >>"$log" ;;
      *) return 0 ;;
    esac
  }
  session_name() { echo "$1"; }
  list_agent_panes() { printf '%%0 impl\n'; }
  last_thread_file() { printf '%s\n' "$transcript"; }
  sleep() { :; }
  PEON_WATCH_MIN=0 cmd_watch "$session" 1000000 || fail 'weekly watch failed without context tokens'
  [ "$(grep -c '@peon_weekly 22.0 1700000000' "$log")" -eq 2 ] || fail 'weekly watch did not read only changed transcripts without context tokens'
)
test_weekly_watch

test_claude_statusline() (
  local socket="peon-weekly-test-$$" session="weekly-test-$$" pane input="$TEST_DIR/statusline-input" rc=0
  local fake_bin="$TEST_DIR/statusline-bin"
  tmux() { command tmux -L "$socket" -f /dev/null "$@"; }
  trap 'tmux kill-session -t "=$session" 2>/dev/null || true' EXIT
  tmux new-session -d -s "$session" 'exec sleep 60'
  pane=$(tmux list-panes -t "$session" -F '#{pane_id}')
  # shellcheck disable=SC2030 # The isolated test session supplies its own socket.
  TMUX="$(tmux display-message -p -t "$pane" '#{socket_path}'),0,0"
  export TMUX TMUX_PANE="$pane"
  printf '%s\n\n' '{"rate_limits":{"seven_day":{"used_percentage":27.5,"resets_at":1700000000}}}' >"$input"
  "$ROOT/peon-code.sh" statusline <"$input" >"$TEST_DIR/statusline-out"
  [ ! -s "$TEST_DIR/statusline-out" ] || fail 'statusline without a user command printed output'
  [ "$(tmux show-options -pqv -t "$pane" @peon_weekly)" = '27.5 1700000000' ] || fail 'Claude statusline did not set weekly limit'
  printf '%s\n' '{"rate_limits":{"seven_day":{"used_percentage":104.6,"resets_at":1700000000}}}' >"$input"
  "$ROOT/peon-code.sh" statusline <"$input"
  [ "$(tmux show-options -pqv -t "$pane" @peon_weekly)" = '100.0 1700000000' ] || fail 'Claude weekly limit exceeds 100 percent'
  tmux set-option -pu -t "$pane" @peon_weekly
  printf '%s\n\n' '{"rate_limits":{"five_hour":{"used_percentage":99,"resets_at":1}}}' >"$input"
  "$ROOT/peon-code.sh" statusline 'cat; exit 7' <"$input" >"$TEST_DIR/statusline-out" || rc=$?
  [ "$rc" -eq 7 ] || fail 'statusline lost the user command exit status'
  cmp "$input" "$TEST_DIR/statusline-out" || fail 'statusline changed user command stdin'
  [ -z "$(tmux show-options -pqv -t "$pane" @peon_weekly)" ] || fail 'missing seven_day sets a weekly limit'
  printf '%s\n' '{"rate_limits":{"seven_day":{"used_percentage":10}}}' >"$input"
  "$ROOT/peon-code.sh" statusline cat <"$input" >"$TEST_DIR/statusline-out"
  [ -z "$(tmux show-options -pqv -t "$pane" @peon_weekly)" ] || fail 'missing reset sets a weekly limit'
  mkdir -p "$fake_bin"
  printf '#!/bin/sh\nexit 1\n' >"$fake_bin/tmux"
  chmod +x "$fake_bin/tmux"
  printf '%s\n\n' '{"rate_limits":{"seven_day":{"used_percentage":27.5,"resets_at":1700000000}}}' >"$input"
  PATH="$fake_bin:$PATH" "$ROOT/peon-code.sh" statusline cat <"$input" >"$TEST_DIR/statusline-out" || fail 'failed tmux blocked the user statusline'
  cmp "$input" "$TEST_DIR/statusline-out" || fail 'failed tmux changed user statusline stdin'
  dd if=/dev/zero bs=65536 count=4 2>/dev/null | tr '\000' x >"$input"
  rc=0
  PATH="$fake_bin:$PATH" "$ROOT/peon-code.sh" statusline 'exit 9' <"$input" || rc=$?
  [ "$rc" -eq 9 ] || fail 'unread large stdin changed the user command exit status'
)
test_claude_statusline

# shellcheck disable=SC2034 # The settings block uses these variables through eval.
test_claude_statusline_settings() (
  local block NORMAL_TUI NORMAL_SETTINGS DENY_SETTINGS STATUSLINE_SETTINGS
  local DENY_SEP CMD SCRIPT_DIR="$TEST_DIR/script path'quoted" BRIEF_DIR="$TEST_DIR/settings"
  local HOME="$TEST_DIR/statusline-home" CLAUDE_CONFIG_DIR config_dir command startups="$TEST_DIR/settings-python-starts"
  local GIT_DENY=('git reset')
  # shellcheck disable=SC2016 # The user command must keep its shell expansions.
  command='printf '\''user "$HOME"\n'\''; cat'$'\n\n'
  mkdir -p "$BRIEF_DIR"
  if ! command -v python3 >/dev/null 2>&1; then return 0; fi
  python3() {
    printf '.\n' >>"$startups"
    builtin command python3 "$@"
  }
  block=$(sed -n '/^# Claude uses the normal screen/,/^# The same list as prose/p' "$ROOT/lib/launch.sh")
  for config_dir in "$TEST_DIR/claude config" "$HOME/.claude"; do
    if [ "$config_dir" = "$HOME/.claude" ]; then
      unset CLAUDE_CONFIG_DIR
    else
      CLAUDE_CONFIG_DIR=$config_dir
      export CLAUDE_CONFIG_DIR
    fi
    mkdir -p "$config_dir"
    python3 - "$config_dir/settings.json" "$command" <<'PYTHON'
import json
import sys
with open(sys.argv[1], "w", encoding="utf-8") as file:
    json.dump({"statusLine": {"command": sys.argv[2]}}, file)
PYTHON
    : >"$startups"
    eval "$block"
    [ "$(wc -l <"$startups")" -eq 1 ] || fail 'settings generation starts Python more than once'
    python3 - "$NORMAL_SETTINGS" "$DENY_SETTINGS" "$SCRIPT_DIR/peon-code.sh" "$command" <<'PYTHON'
import json
import shlex
import sys
for path in sys.argv[1:3]:
    with open(path, encoding="utf-8") as file:
        data = json.load(file)
    assert data["tui"] == "default"
    assert data["statusLine"]["type"] == "command"
    assert shlex.split(data["statusLine"]["command"]) == [sys.argv[3], "statusline", sys.argv[4]]
PYTHON
  done
  # shellcheck disable=SC2317 # The evaluated settings block checks python3.
  command() {
    if [ "$*" = '-v python3' ]; then return 1; fi
    builtin command "$@"
  }
  eval "$block"
  assert_not_contains "$NORMAL_SETTINGS" 'statusLine'
  assert_not_contains "$DENY_SETTINGS" 'statusLine'
)
test_claude_statusline_settings

test_usage_report() (
  local socket="peon-usage-test-$$" session="usage-test-$$" pane name bin report project original_path=$PWD
  # shellcheck source=lib/tmux.sh
  source "$ROOT/lib/tmux.sh"
  # shellcheck source=lib/resume.sh
  source "$ROOT/lib/resume.sh"
  # shellcheck source=lib/session.sh
  source "$ROOT/lib/session.sh"
  tmux() { command tmux -L "$socket" -f /dev/null "$@"; }
  die() { echo "peon-code: $*" >&2; exit 1; }
  trap 'tmux kill-session -t "=$session" 2>/dev/null || true' EXIT
  project="$TEST_DIR/project"
  mkdir -p "$project" "$TEST_DIR/claude-transcripts" "$TEST_DIR/codex-transcripts"
  create_agent_session "$session" 4 0
  for pane in "${PANE_IDS[@]}"; do
    case $pane in
      "${PANE_IDS[0]}") name=boss; bin=claude ;;
      "${PANE_IDS[1]}") name=impl; bin=codex ;;
      "${PANE_IDS[2]}") name=helper; bin=claude ;;
      *) name=other; bin=copilot ;;
    esac
    tmux set-option -p -t "$pane" @peon_name "$name"
    tmux set-option -p -t "$pane" @peon_bin "$bin"
    tmux respawn-pane -k -t "$pane" -c "$project" 'exec sleep 60'
    wait_agent_ready "$pane" || fail 'usage test pane did not start'
  done
  # shellcheck disable=SC2034,SC2317 # last_thread_file invokes providers in its scope.
  claude_resume_dir() { dir="$TEST_DIR/claude-transcripts"; }
  # shellcheck disable=SC2034,SC2317
  codex_resume_dir() { dir="$TEST_DIR/codex-transcripts"; cwd="\"cwd\":\"$PWD\""; }
  cmd_usage "$session" >"$TEST_DIR/usage-empty.out"
  assert_contains "$TEST_DIR/usage-empty.out" "peon-code: token usage for session $session"
  [ "$(grep -c 'no transcript' "$TEST_DIR/usage-empty.out")" -eq 3 ] || fail 'supported panes without transcripts were not reported'
  assert_contains "$TEST_DIR/usage-empty.out" 'no usage logged'
  tmux has-session -t "=$session" || fail 'usage killed the session'
  printf 'agent boss of peon-code session %s,\nagent helper of peon-code session %s,\n' "$session" "$session" >"$TEST_DIR/claude-transcripts/thread.jsonl"
  printf '{"cwd":"%s","prompt":"agent impl of peon-code session %s,"}\n' "$project" "$session" >"$TEST_DIR/codex-transcripts/thread.jsonl"
  cmd_usage "$session" >"$TEST_DIR/usage-unlogged.out"
  [ "$(grep -c 'no usage logged' "$TEST_DIR/usage-unlogged.out")" -eq 4 ] || fail 'transcripts without usage were not reported'
  write_usage_fixtures
  printf 'agent boss of peon-code session %s,\nagent helper of peon-code session %s,\n' "$session" "$session" >>"$TEST_DIR/claude.jsonl"
  printf '{"cwd":"%s","prompt":"agent impl of peon-code session %s,"}\n' "$project" "$session" >>"$TEST_DIR/codex.jsonl"
  cp "$TEST_DIR/claude.jsonl" "$TEST_DIR/claude-transcripts/thread.jsonl"
  cp "$TEST_DIR/codex.jsonl" "$TEST_DIR/codex-transcripts/thread.jsonl"
  cmd_usage "$session" >"$TEST_DIR/usage.out"
  assert_contains "$TEST_DIR/usage.out" 'input 14 cache read 130 cache write 26 output 16 total 186'
  assert_contains "$TEST_DIR/usage.out" 'input 80 cache read 120 cache write 0 output 50 total 250'
  assert_contains "$TEST_DIR/usage.out" 'total: input 28 cache read 260 cache write 52 output 32 total 372'
  assert_contains "$TEST_DIR/usage.out" 'total: input 80 cache read 120 cache write 0 output 50 total 250'
  [ "$(pwd)" = "$original_path" ] || fail 'usage changed the caller working directory'
  [ "$(cmd_usage "$session-missing")" = "peon-code: no session $session-missing" ] || fail 'missing usage session has the wrong result'
  tmux set-option -t "$session" @peon_code 0
  if (cmd_usage "$session") >"$TEST_DIR/usage-foreign.out" 2>"$TEST_DIR/usage-foreign.err"; then
    fail 'usage accepted a foreign session'
  fi
  assert_contains "$TEST_DIR/usage-foreign.err" "session $session was not created by peon-code"
  tmux set-option -t "$session" @peon_code 1
  report=$(cmd_dismiss "$session")
  case $report in
    "peon-code: token usage for session $session"*"peon-code: killing session $session") ;;
    *) fail 'dismiss did not print usage before killing the session' ;;
  esac
  if tmux has-session -t "=$session" 2>/dev/null; then fail 'dismiss did not kill the test session'; fi
)
test_usage_report

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
