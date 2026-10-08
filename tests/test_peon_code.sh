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
    case $bin in
      claude|codex|copilot)
        [ -n "$marker" ] || { echo "FAIL: $provider has no prompt marker" >&2; exit 1; } ;;
    esac
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
  CLI_ALL_PROMPT_MARKERS="$CLI_ALL_PROMPT_MARKERS|$(extra_prompt_marker)"
  CLI_ALL_PASTE_PLACEHOLDERS+=("$(extra_paste_placeholder)")
  # shellcheck disable=SC2317 # A cached parser must not query a provider again.
  extra_prompt_marker() { echo 'FAIL: prompt marker read after load' >&2; return 1; }
  # shellcheck disable=SC2317 # A cached parser must not query a provider again.
  extra_paste_placeholder() { echo 'FAIL: paste placeholder read after load' >&2; return 1; }
  # shellcheck source=lib/cli.sh
  source "$ROOT/lib/cli.sh"
  tmux() {
    case $1 in
      display) printf '0\n' ;;
      capture-pane) printf '» draft\n' ;;
    esac
  }
  cli_select_pane %9
  box_is_paste_placeholder '[Extra paste]' || exit 1
  box_holds_message '[Extra paste]' 'draft text' || exit 1
  pane_has_menu '» 1. Yes' 0 || exit 1
  [ "$(pane_free_text_number '» 2. Type something.')" = 2 ] || exit 1
  [ "$(printf '\033[2m» hint\033[0m typed\n' | strip_styles 1)" = '»      typed' ] || exit 1
  [ "$(pane_box_text %9)" = draft ] || exit 1
  cli_call claude context_tokens || exit 1
  if cli_call copilot context_tokens; then exit 1; fi
  [ -z "$(cli_call copilot context_tokens unused.jsonl)" ] || exit 1
)
test_cli_provider_parsers

# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"

test_copilot_captured_input() (
  local capture box rc=0
  # shellcheck source=lib/input.sh
  source "$ROOT/lib/input.sh"
  # Copilot 1.0.63 input rows captured at 120 columns, with their SGR styles.
  local rows=$'\033[2m────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────\n\033[0m❯\n\033[2m────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────'
  tmux() {
    case $1 in
      show-options) printf 'copilot\n' ;;
      display)
        case $4 in
          '#{pane_in_mode}') printf '0\n' ;;
          '#{cursor_y}') printf '1\n' ;;
        esac ;;
      capture-pane) printf '%s\n' "$capture" ;;
    esac
  }
  cli_select_pane %9
  capture=$rows
  box=$(pane_box_text %9) || fail 'Copilot idle input could not be read'
  [ -z "$box" ] || fail 'Copilot idle input is not empty'
  pane_box_ready %9 || fail 'Copilot idle input is not ready'
  capture=${rows/❯/❯ copilot capture draft}
  [ "$(pane_box_text %9)" = 'copilot capture draft' ] || fail 'Copilot held text could not be read'
  pane_box_ready %9 || rc=$?
  [ "$rc" -eq 4 ] || fail 'Copilot held text is not busy'
  capture=${rows/❯/❯ [Paste #1 - 24 lines]}
  box=$(pane_box_text %9) || fail 'Copilot pasted input could not be read'
  [ "$box" = '[Paste #1 - 24 lines]' ] || fail 'Copilot paste placeholder changed'
  box_is_paste_placeholder "$box" || fail 'Copilot paste placeholder was not recognized'
  box_holds_message "$box" 'harmless multiline capture text' || fail 'Copilot paste was not recognized as held text'
  if box_is_paste_placeholder 'draft [Paste #1 - 24 lines]'; then fail 'Copilot placeholder accepted typed text'; fi
)
test_copilot_captured_input

test_cli_pane_selection() (
  local pane_bin=codex capture='❯ ' rc=0
  # shellcheck source=lib/input.sh
  source "$ROOT/lib/input.sh"
  # shellcheck source=lib/tmux.sh
  source "$ROOT/lib/tmux.sh"
  # shellcheck source=lib/delivery.sh
  source "$ROOT/lib/delivery.sh"
  tmux() {
    case $1 in
      show-options) printf '%s\n' "$pane_bin" ;;
      display) printf '0\n' ;;
      capture-pane) printf '%s\n' "$capture" ;;
      display-message) printf 'provider-test:%%9\n' ;;
    esac
  }
  sleep() { :; }
  pane_box_ready %9 || rc=$?
  [ "$rc" -eq 2 ] || fail 'Codex readiness accepts a Claude marker'
  [ "$CLI_PROMPT_MARKERS" = '›' ] || fail 'Codex did not select its own marker'
  box_is_paste_placeholder '[Pasted Content 20 chars]' || fail 'Codex placeholder was not selected'
  if box_is_paste_placeholder '[Pasted text #2]'; then fail 'Codex accepts a Claude placeholder'; fi
  capture='› '
  pane_box_ready %9 || fail 'Codex readiness rejects its own marker'
  CLI_PROMPT_MARKERS='❯'
  answer_dialog %9 '*Resume from summary*'
  [ "$CLI_PROMPT_MARKERS" = '›' ] || fail 'dialog check did not select its pane'
  CLI_PASTE_PLACEHOLDERS=('^unrelated$')
  with_pane_delivery %9 box_is_paste_placeholder '[Pasted Content 20 chars]' ||
    fail 'delivery did not select its pane'
  pane_bin=''
  cli_select_pane %9
  [ "$CLI_PROMPT_MARKERS" = "$CLI_ALL_PROMPT_MARKERS" ] || fail 'pane without a bin lost merged markers'
  for capture in '› ' '❯ '; do
    pane_box_ready %9 || fail 'pane without a bin rejects a merged marker'
  done
  pane_bin=gemini
  cli_select_pane %9
  [ "$CLI_PROMPT_MARKERS" = "$CLI_ALL_PROMPT_MARKERS" ] || fail 'empty marker did not use merged markers'
  box_is_paste_placeholder '[Pasted text #2]' || fail 'empty placeholder did not use merged placeholders'
  # shellcheck disable=SC2317 # cli_call invokes the provider by name.
  codex_paste_placeholder() { :; }
  pane_bin=codex
  cli_select_pane %9
  [ "$CLI_PROMPT_MARKERS" = '›' ] || fail 'empty placeholder changed the selected marker'
  box_is_paste_placeholder '[Pasted text #2]' || fail 'empty placeholder did not fall back independently'
)
test_cli_pane_selection

test_cli_pane_settled() (
  local pane_bin=codex capture='❯ ' reads="$TEST_DIR/provider-reads" invalid_read=0 invalid_capture='' redraw=0
  # shellcheck source=lib/tmux.sh
  source "$ROOT/lib/tmux.sh"
  # shellcheck source=lib/input.sh
  source "$ROOT/lib/input.sh"
  tmux() {
    local n
    case $1 in
      show-options) printf '%s\n' "$pane_bin" ;;
      display) printf '0\n' ;;
      capture-pane)
        n=$(cat "$reads"); n=$((n + 1)); printf '%s\n' "$n" >"$reads"
        if [ "$n" -eq "$invalid_read" ]; then printf '%s\n' "$invalid_capture"
        else printf '%s\n' "$capture"; fi
        [ "$redraw" -eq 0 ] || printf 'redrawing %s\n' "$n"
        return 0 ;;
    esac
  }
  sleep() { :; }
  check_settled() {
    local want=$1 tries=$2 expected_reads=$3 rc=0
    printf '0\n' >"$reads"
    wait_pane_settled %9 "$tries" || rc=$?
    [ "$rc" -eq "$want" ] || fail "settle for $pane_bin returned $rc, expected $want"
    [ "$(cat "$reads")" -eq "$expected_reads" ] || fail "settle for $pane_bin used the wrong capture count"
  }
  check_settled 1 3 3
  capture='› '
  check_settled 0 3 2
  pane_bin=''
  capture='❯ '
  check_settled 0 3 2
  capture='Ready without a marker'
  check_settled 1 3 3
  pane_bin=gemini
  check_settled 1 2 2
  check_settled 0 3 3
  invalid_read=3
  check_settled 0 6 6
  invalid_capture=$'Choose an option\nEnter to confirm'
  check_settled 0 6 6
  invalid_read=0
  capture=' '
  check_settled 1 3 3
  capture=$'Choose an option\nEnter to confirm'
  check_settled 1 3 3
  capture='Ready without a marker'
  redraw=1
  check_settled 1 3 3
  redraw=0
  pane_bin=custom-agent
  check_settled 0 3 3
)
test_cli_pane_settled

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
      display) echo 100 ;;
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

test_watch_new_transcript() (
  local socket="peon-watch-new-test-$$" session="watch-new-test-$$" pane ticks=0
  local transcripts="$TEST_DIR/watch-transcripts" old_transcript new_transcript
  # shellcheck source=lib/tmux.sh
  source "$ROOT/lib/tmux.sh"
  # shellcheck source=lib/resume.sh
  source "$ROOT/lib/resume.sh"
  # shellcheck source=lib/watch.sh
  source "$ROOT/lib/watch.sh"
  tmux() { command tmux -L "$socket" -f /dev/null "$@"; }
  trap 'tmux kill-session -t "=$session" 2>/dev/null || true' EXIT
  tmux new-session -d -s "$session" 'exec sleep 60'
  pane=$(tmux list-panes -t "$session" -F '#{pane_id}')
  tmux set-option -p -t "$pane" @peon_name impl
  tmux set-option -p -t "$pane" @peon_bin codex
  wait_agent_ready "$pane" || fail 'watch test pane did not start'
  mkdir -p "$transcripts"
  old_transcript="$transcripts/old.jsonl"
  new_transcript="$transcripts/new.jsonl"
  # shellcheck disable=SC2034,SC2317 # last_thread_file invokes providers in its scope.
  codex_resume_dir() { dir=$transcripts; }
  printf '{"prompt":"agent impl of peon-code session %s,","total_token_usage":{"input_tokens":100,"cached_input_tokens":30,"output_tokens":20}}\n' "$session" >"$old_transcript"
  sleep() {
    ticks=$((ticks + 1))
    case $ticks in
      1)
        [ "$(tmux show-options -pqv -t "$pane" @peon_usage)" = '70 30 0 20' ] || fail 'watch did not read the old transcript'
        command sleep 1
        printf '{"prompt":"agent impl of peon-code session %s,","total_token_usage":{"input_tokens":200,"cached_input_tokens":40,"output_tokens":50}}\n' "$session" >"$new_transcript"
        [ "$(wc -c <"$old_transcript")" -eq "$(wc -c <"$new_transcript")" ] || fail 'watch transcript fixtures differ in size'
        ;;
      *)
        [ "$(tmux show-options -pqv -t "$pane" @peon_usage)" = '160 40 0 50' ] || fail 'watch did not switch to the newer transcript'
        tmux kill-session -t "=$session"
        ;;
    esac
  }
  PEON_WATCH_MIN=0 PEON_WATCH_TICK=0.01 cmd_watch "$session" 1000000 || fail 'watch failed after a new transcript appeared'
)
test_watch_new_transcript

test_watch_ignores_old_transcript() (
  local socket="peon-watch-old-test-$$" session="watch-old-test-$$" pane ticks=0
  local transcripts="$TEST_DIR/watch-old-transcripts" old_transcript new_transcript
  # shellcheck source=lib/tmux.sh
  source "$ROOT/lib/tmux.sh"
  # shellcheck source=lib/resume.sh
  source "$ROOT/lib/resume.sh"
  # shellcheck source=lib/watch.sh
  source "$ROOT/lib/watch.sh"
  tmux() { command tmux -L "$socket" -f /dev/null "$@"; }
  trap 'tmux kill-session -t "=$session" 2>/dev/null || true' EXIT
  mkdir -p "$transcripts"
  old_transcript="$transcripts/old.jsonl"
  new_transcript="$transcripts/new.jsonl"
  printf '{"prompt":"agent impl of peon-code session %s,","total_token_usage":{"input_tokens":100,"cached_input_tokens":30,"output_tokens":20}}\n' "$session" >"$old_transcript"
  command sleep 1
  tmux new-session -d -s "$session" 'exec sleep 60'
  pane=$(tmux list-panes -t "$session" -F '#{pane_id}')
  tmux set-option -p -t "$pane" @peon_name impl
  tmux set-option -p -t "$pane" @peon_bin codex
  wait_agent_ready "$pane" || fail 'old-transcript watch test pane did not start'
  # shellcheck disable=SC2034,SC2317 # last_thread_file invokes providers in its scope.
  codex_resume_dir() { dir=$transcripts; }
  [ "$(last_thread_file "agent impl of peon-code session $session," codex)" = "$old_transcript" ] ||
    fail 'unfiltered transcript lookup lost the old transcript'
  sleep() {
    ticks=$((ticks + 1))
    case $ticks in
      1)
        [ -z "$(tmux show-options -pqv -t "$pane" @peon_usage)" ] || fail 'watch read a pre-session transcript'
        command sleep 1
        printf '{"prompt":"agent impl of peon-code session %s,","total_token_usage":{"input_tokens":200,"cached_input_tokens":40,"output_tokens":50}}\n' "$session" >"$new_transcript"
        ;;
      *)
        [ "$(tmux show-options -pqv -t "$pane" @peon_usage)" = '160 40 0 50' ] || fail 'watch missed the new transcript after ignoring the old one'
        tmux kill-session -t "=$session"
        ;;
    esac
  }
  TZ=EST5 PEON_WATCH_MIN=0 PEON_WATCH_TICK=0.01 cmd_watch "$session" 1000000 || fail 'watch failed with a pre-session transcript'
)
test_watch_ignores_old_transcript

test_watch_cleanup() (
  local script="$TEST_DIR/watch-cleanup.sh" mode watch_dir ref watcher="" child="" rc i
  trap '[ -z "$child" ] || kill -TERM "$child" 2>/dev/null || true' EXIT
  cat >"$script" <<'WATCH'
set -euo pipefail
source "$1/lib/watch.sh"
mode=$2
session_name() { printf '%s\n' "$1"; }
tmux() { case $1 in display) command date +%s ;; esac; return 0; }
list_agent_panes() { :; }
sleep() {
  printf '%s\n' "$$" >"$TMPDIR/ready"
  [ "$mode" != error ] || return 1
  command sleep 0.05
}
trap 'printf "caller\n" >"$TMPDIR/caller-cleanup"' EXIT
cmd_watch "peon-watch-cleanup-$$" 1000
WATCH
  for mode in term error; do
    watch_dir="$TEST_DIR/watch cleanup $mode"
    mkdir -p "$watch_dir"
    set -- bash "$script" "$ROOT" "$mode"
    if command -v setsid >/dev/null; then
      if command -v systemd-run >/dev/null && systemctl --user show-environment >/dev/null 2>&1; then
        set -- systemd-run --user --scope -q -p OOMPolicy=continue "$@"
      fi
      set -- setsid --wait "$@"
    fi
    TMPDIR="$watch_dir" "$@" >"$watch_dir/output" 2>&1 &
    watcher=$!
    for i in 1 2 3 4 5 6 7 8 9 10; do
      [ ! -s "$watch_dir/ready" ] || break
      command sleep 0.1
    done
    [ -s "$watch_dir/ready" ] || fail "cleanup watcher did not start: $(cat "$watch_dir/output")"
    child=$(cat "$watch_dir/ready")
    set -- "$watch_dir"/peon-code-watch.*
    ref=$1
    if [ "$mode" = term ]; then
      [ -f "$ref" ] || fail 'watcher created no timestamp reference'
      kill -TERM "$child"
    fi
    rc=0
    wait "$watcher" || rc=$?
    child=""
    case $mode:$rc in term:143|error:1) ;; *) fail "watch cleanup exited $rc for $mode" ;; esac
    [ ! -e "$ref" ] || fail "watch left its reference after $mode"
    [ "$(cat "$watch_dir/caller-cleanup")" = caller ] || fail "watch lost the caller EXIT trap after $mode"
  done
)
test_watch_cleanup

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
