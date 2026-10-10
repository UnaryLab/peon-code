#!/usr/bin/env bash
set -euo pipefail
CASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/helpers.sh
. "$CASE_DIR/../helpers.sh"
SCRIPT_DIR=$ROOT
die() { printf 'peon-code: %s\n' "$*" >&2; exit 1; }
# shellcheck source=lib/input.sh
source "$ROOT/lib/input.sh"
# shellcheck source=lib/delivery.sh
source "$ROOT/lib/delivery.sh"
# shellcheck source=lib/tmux.sh
source "$ROOT/lib/tmux.sh"
# shellcheck source=lib/commands.sh
source "$ROOT/lib/commands.sh"
# shellcheck source=lib/resume.sh
source "$ROOT/lib/resume.sh"
# shellcheck source=lib/watch.sh
source "$ROOT/lib/watch.sh"

bin_dir="$TEST_DIR/swap-bin"
mkdir -p "$bin_dir"
cat >"$bin_dir/tmux" <<'FAKE_TMUX'
#!/usr/bin/env bash
set -eu
[ "${1:-}" != -V ] || { printf 'tmux 3.4\n'; exit 0; }
printf '%s\n' "$*" >>"$SWAP_STATE/log"
for last do :; done
case $1 in
  has-session) exit 0 ;;
  list-panes) printf '%%1 %s\n' "$(cat "$SWAP_STATE/peon_name")" ;;
  show-options)
    if [ "$2" = -p ]; then
      for option in peon_cmd peon_bin peon_launch peon_fresh peon_weekly peon_usage; do
        [ ! -f "$SWAP_STATE/$option" ] || printf '@%s %s\n' "$option" "$(cat "$SWAP_STATE/$option")"
      done
    else cat "$SWAP_STATE/${last#@}"; fi ;;
  set)
    if [ "$2" = -pu ]; then rm -f "$SWAP_STATE/${5#@}"
    else printf '%s\n' "$5" >"$SWAP_STATE/${4#@}"; fi ;;
  display-message)
    if [ "$last" = '#{pid}:#{session_id}:#{pane_pid}' ] && [ -f "$SWAP_STATE/identity" ]; then
      cat "$SWAP_STATE/identity"
    else printf '%s:%%1\n' "$SWAP_STATE"; fi ;;
  display)
    case $last in
      '#{pane_current_command}') cat "$SWAP_STATE/current" ;;
      '#{pane_current_path}') cat "$SWAP_STATE/project_path" ;;
      '#{session_name}') printf 'swap-test\n' ;;
      '#{pane_in_mode}') cat "$SWAP_STATE/in_mode" ;;
      '#{cursor_y}') printf '1\n' ;;
    esac ;;
  load-buffer) cat >"$SWAP_STATE/buffer" ;;
  paste-buffer) cp "$SWAP_STATE/buffer" "$SWAP_STATE/box" ;;
  capture-pane)
    if [ -s "$SWAP_STATE/dialog" ]; then printf 'Choose an option\n> Continue\n────\n'; exit 0; fi
    bin=$(cat "$SWAP_STATE/screen_bin")
    case $bin in claude) marker='❯' ;; *) marker='›' ;; esac
    printf 'output\n%s %s\n────\n' "$marker" "$(cat "$SWAP_STATE/box")" ;;
  send-keys)
    if [ "$last" = C-u ]; then
      : >"$SWAP_STATE/box"
    elif [ "$last" = Enter ]; then
      text=$(cat "$SWAP_STATE/box")
      if [ "$text" = /exit ]; then
        [ -e "$SWAP_STATE/no_quit" ] || printf 'bash\n' >"$SWAP_STATE/current"
        printf '/exit\n' >>"$SWAP_STATE/quits"
        printf 'quit\n' >>"$SWAP_STATE/events"
      else
        printf 'node\n' >"$SWAP_STATE/current"
        cat "$SWAP_STATE/peon_bin" >"$SWAP_STATE/screen_bin"
        printf '%s\n' "$text" >>"$SWAP_STATE/launches"
      fi
      : >"$SWAP_STATE/box"
    fi ;;
  list-clients) : ;;
esac
FAKE_TMUX
chmod +x "$bin_dir/tmux"
for bin in claude codex; do
  cat >"$bin_dir/$bin" <<'FAKE_CLI'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SWAP_STATE/probes"
printf 'probe\n' >>"$SWAP_STATE/events"
pwd >"$SWAP_STATE/probe_cwd"
printf 'probe stdout\n'
if [ "${SWAP_PROBE_MODE:-}" = fail ]; then
  printf 'first diagnostic\nmodel is not available\n' >&2
  exit 7
fi
if [ "${SWAP_PROBE_MODE:-}" = blank ]; then exit 7; fi
if [ "${SWAP_PROBE_MODE:-}" = hang ]; then
  trap '' TERM
  printf '%s\n' "$$" >"$SWAP_STATE/probe_pid"
  while :; do :; done
fi
if [ "${SWAP_PROBE_MODE:-}" = slow ]; then
  printf '%s\n' "$$" >"$SWAP_STATE/probe_pid"
  while [ ! -f "$SWAP_STATE/release" ]; do sleep 0.1; done
fi
if [ "${SWAP_PROBE_MODE:-}" = changed ]; then
  printf 'replacement-pane\n' >"$SWAP_STATE/identity"
fi
exit 0
FAKE_CLI
  chmod +x "$bin_dir/$bin"
done
printf '#!/bin/sh\nexit 1\n' >"$bin_dir/systemd-run"
printf '#!/bin/sh\nexit 0\n' >"$bin_dir/unknown-swap-agent"
chmod +x "$bin_dir/systemd-run" "$bin_dir/unknown-swap-agent"
PATH="$bin_dir:$PATH"
export PATH SWAP_STATE SWAP_TRANSCRIPT
sleep() { case $1 in 0.1|0.2) command sleep "$1" ;; esac; }
wait_agent_ready() {
  printf 'ready\n' >>"$SWAP_STATE/events"
  case $(cat "$SWAP_STATE/peon_swap") in done*) fail 'swap became done before readiness' ;; esac
  [ "${SWAP_READY:-1}" = 1 ]
}
wait_pane_settled() { return 1; }
last_thread_file() {
  printf '%s\n' "$2" >>"$SWAP_STATE/lookups"
  pwd >"$SWAP_STATE/lookup_cwd"
  printf '%s\n' "${SWAP_TRANSCRIPT:-}"
}
eval "$(declare -f watch_restart | sed '1s/watch_restart/real_watch_restart/')"
watch_restart() {
  printf 'restart\n' >>"$SWAP_STATE/restarts"
  real_watch_restart "$@"
}

fake_trust_project() {
  printf 'trust\n' >>"$SWAP_STATE/events"
  printf '%s\n' "$@" >>"$SWAP_STATE/trust_dirs"
  pwd >"$SWAP_STATE/trust_cwd"
  return "${SWAP_TRUST_FAIL:-0}"
}
claude_trust_project() { fake_trust_project "$@"; }
codex_trust_project() { fake_trust_project "$@"; }
fake_brief_after_start() {
  printf 'brief\n' >>"$SWAP_STATE/events"
  case $(cat "$SWAP_STATE/peon_swap") in done*) fail 'swap became done before brief delivery' ;; esac
  return "${SWAP_BRIEF_FAIL:-0}"
}
claude_brief_after_start() { fake_brief_after_start; }
codex_brief_after_start() { fake_brief_after_start; }

# Detached jobs load fake trust hooks from a private copy, never user config.
job_root="$TEST_DIR/swap-job"
mkdir -p "$job_root"
cp -R "$ROOT/lib" "$job_root/"
cp "$ROOT/peon-code.sh" "$ROOT/VERSION" "$job_root/"
declare -f fake_trust_project claude_trust_project codex_trust_project fake_brief_after_start claude_brief_after_start codex_brief_after_start >>"$job_root/lib/cli/codex.sh"
SCRIPT_DIR=$job_root

setup_swap() {
  local name=${3:-impl}
  SWAP_STATE="$TEST_DIR/$1"
  SWAP_TRANSCRIPT=""
  mkdir -p "$SWAP_STATE/project"
  printf '%s\n' "$SWAP_STATE/project" >"$SWAP_STATE/peon_project_dir"
  printf '%s\n' "$SWAP_STATE/project" >"$SWAP_STATE/project_path"
  printf '%s\n' "$2" >"$SWAP_STATE/peon_cmd"
  printf '%s\n' "${2%% *}" >"$SWAP_STATE/peon_bin"
  printf '%s\n' "${2%% *}" >"$SWAP_STATE/screen_bin"
  printf '%s\n' "$name" >"$SWAP_STATE/peon_name"
  printf 'node\n' >"$SWAP_STATE/current"
  printf '0\n' >"$SWAP_STATE/in_mode"
  : >"$SWAP_STATE/dialog"
  printf '0\n' >"$SWAP_STATE/peon_main"
  printf '1\n' >"$SWAP_STATE/peon_code"
  printf '1\n' >"$SWAP_STATE/peon_restart"
  printf '%s\n' "$$" >"$SWAP_STATE/peon_watch_pid"
  printf '0\n' >"$SWAP_STATE/peon_fresh"
  : >"$SWAP_STATE/peon_swap"
  printf '%s\n' "$SWAP_STATE/brief.md" >"$SWAP_STATE/peon_brief"
  printf '{}\n' >"$SWAP_STATE/normal-screen.json"
  printf '{}\n' >"$SWAP_STATE/deny-git.json"
  printf 'You are %s (%s), agent %s of peon-code session swap-test,\nStart every message with [from %s %s %%1]\npane %%1: %s (%s)\npane %%2: helper (%s)\n' \
    "$name" "$2" "$name" "${2%% *}" "$name" "$name" "$2" "$2" >"$SWAP_STATE/brief.md"
  cp "$SWAP_STATE/brief.md" "$SWAP_STATE/original.md"
  : >"$SWAP_STATE/box"
  : >"$SWAP_STATE/log"
}

assert_unchanged() {
  cmp "$SWAP_STATE/original.md" "$SWAP_STATE/brief.md" || fail 'rejected swap changed its brief'
  if sed '/set -pt .* @peon_swap/d' "$SWAP_STATE/log" | grep -F 'set -pt ' >/dev/null; then
    fail 'rejected swap changed pane command options'
  fi
  [ ! -e "$SWAP_STATE/quits" ] || fail 'rejected swap sent quit'
}

# Run the reserved job directly so result checks do not depend on scheduling.
run_swap() (
  local identity="$SWAP_STATE:%1" name=$1 command=$2 session=${3:-swap-test}
  # shellcheck disable=SC2317 # slash_locked calls the pane parser stub.
  if [ -s "$SWAP_STATE/dialog" ]; then pane_box_text() { return 1; }; fi
  with_pane_delivery %1 swap_reserve_locked %1 "$command" "$identity" "$SWAP_STATE/job.log" || return $?
  [ "$(cat "$SWAP_STATE/peon_swap")" = "checking $command" ] || fail 'swap reservation missing'
  swap_job %1 "$identity" "$SWAP_STATE/job.log" "$name" "$command" "$session" scoped || return $?
  if [ "${4:-}" != defer ] && [ -s "$SWAP_STATE/peon_swap_pending" ]; then
    watch_restart "$session" %1 "$name" '' "$(cat "$SWAP_STATE/peon_launch")"
  fi
)

run_fields() (
  # Run the immutable command handed to the launcher without a scheduling race.
  swap_start_job() { swap_job "$@" scoped; }
  cmd_swap "$@"
  if [ -s "$SWAP_STATE/peon_swap_pending" ]; then
    watch_restart swap-test %1 impl '' "$(cat "$SWAP_STATE/peon_launch")"
  fi
)

setup_swap no-change 'claude --model current'
printf 'old launch\n' >"$SWAP_STATE/peon_launch"
printf 'weekly\n' >"$SWAP_STATE/peon_weekly"
printf 'usage\n' >"$SWAP_STATE/peon_usage"
for option in peon_cmd peon_bin peon_launch peon_fresh peon_weekly peon_usage; do
  cp "$SWAP_STATE/$option" "$SWAP_STATE/old-$option"
done
if (run_fields impl - current - swap-test) >"$TEST_DIR/no-change.out" 2>"$TEST_DIR/no-change.err"; then fail 'no-change swap was accepted'; fi
[ "$(cat "$TEST_DIR/no-change.err")" = 'peon-code: impl already runs claude --model current; nothing to change' ] || fail 'no-change swap returned the wrong error'
assert_unchanged
[ ! -e "$SWAP_STATE/probes" ] || fail 'no-change swap ran a probe'
[ "$(cat "$SWAP_STATE/peon_swap")" = '' ] || fail 'no-change swap wrote a marker'
if grep -F 'set ' "$SWAP_STATE/log" >/dev/null; then fail 'no-change swap wrote tmux options'; fi
for option in peon_cmd peon_bin peon_launch peon_fresh peon_weekly peon_usage; do
  cmp "$SWAP_STATE/old-$option" "$SWAP_STATE/$option" || fail "no-change swap changed $option"
done

# shellcheck disable=SC2016 # Stored commands must remain literal during composition.
stored_args=' --keep "two words" --literal $(touch peon-swap-substitution) --tick `touch peon-swap-backtick` --nested "$(printf "%s --model hidden" "$(printf inner)")" --brace ${value:-two words} --model old --effort low --model duplicate --effort high'
# shellcheck disable=SC2016 # Expected output retains the exact literal shell words.
expected_args=' --keep "two words" --literal $(touch peon-swap-substitution) --tick `touch peon-swap-backtick` --nested "$(printf "%s --model hidden" "$(printf inner)")" --brace ${value:-two words} --model new --effort medium'
composed=$(cd "$TEST_DIR" && cli_call claude swap_args "$stored_args" new medium)
[ "$composed" = "$expected_args" ] || fail 'Claude swap composition changed literal unrelated shell words'
if [ -e "$TEST_DIR/peon-swap-substitution" ] || [ -e "$TEST_DIR/peon-swap-backtick" ]; then
  fail 'swap composition executed stored shell substitutions'
fi
[ "$(cli_call claude swap_args "$stored_args" - -)" = "$stored_args" ] || fail 'hyphens changed existing model or effort flags'
stored_codex=' --keep "two words" --model old -c model_reasoning_effort=low -c other="two words" --model duplicate -c model_reasoning_effort=high'
[ "$(cli_call codex swap_args "$stored_codex" new xhigh)" = ' --keep "two words" -c other="two words" --model new -c model_reasoning_effort=xhigh' ] || fail 'Codex swap composition did not replace duplicate provider flags'
[ "$(cli_call codex swap_args "$stored_codex" - -)" = "$stored_codex" ] || fail 'Codex hyphens changed existing flags'
if cli_call unknown-swap-agent swap_args '' new -; then fail 'unknown CLI supports field composition'; fi
aliases=' -m old --config model_reasoning_effort=low --config other="two words" -m=duplicate --config=model_reasoning_effort=high'
[ "$(cli_call codex swap_args "$aliases" next xhigh)" = ' --config other="two words" --model next -c model_reasoning_effort=xhigh' ] || fail 'Codex swap kept model or effort aliases'
[ "$(cli_call codex swap_args ' -c=model_reasoning_effort=low -c=other=value' - high)" = ' -c=other=value -c model_reasoning_effort=high' ] || fail 'Codex swap kept inline effort config'

setup_swap fields-same 'codex --sandbox workspace-write --model old -c model_reasoning_effort=low -c other="two words"'
(run_fields impl - next - swap-test) >"$TEST_DIR/fields-same.out" 2>"$TEST_DIR/fields-same.err"
[ "$(cat "$SWAP_STATE/peon_cmd")" = 'codex --sandbox workspace-write -c model_reasoning_effort=low -c other="two words" --model next' ] || fail 'same-CLI fields did not preserve unrelated args and effort'
assert_contains "$SWAP_STATE/probes" '--model next exec reply ok'

setup_swap fields-cross 'claude --settings old.json --effort high --model old'
(run_fields impl codex next - swap-test) >"$TEST_DIR/fields-cross.out" 2>"$TEST_DIR/fields-cross.err"
[ "$(cat "$SWAP_STATE/peon_cmd")" = 'codex --model next' ] || fail 'cross-CLI fields retained old args or effort'

setup_swap fields-cross-bare 'claude --model old --effort high'
(run_fields impl codex - - swap-test) >"$TEST_DIR/fields-cross-bare.out" 2>"$TEST_DIR/fields-cross-bare.err"
[ "$(cat "$SWAP_STATE/peon_cmd")" = codex ] || fail 'cross-CLI hyphens copied old model or effort'

setup_swap same "claude --model 'old[.*]&\name'"
new="claude --model 'new&[x]\path'"
(run_swap impl "$new" swap-test defer) >"$TEST_DIR/same.out" 2>"$TEST_DIR/same.err"
assert_contains "$SWAP_STATE/brief.md" "You are impl ($new), agent impl"
assert_contains "$SWAP_STATE/brief.md" '[from claude impl %1]'
assert_contains "$SWAP_STATE/brief.md" "pane %2: helper (claude --model 'old[.*]&\name')"
[ "$(cat "$SWAP_STATE/peon_cmd")" = "$new" ] || fail 'swap did not store full command'
assert_contains "$SWAP_STATE/peon_launch" "$new --settings "
[ "$(cat "$SWAP_STATE/quits")" = /exit ] || fail 'swap did not quit once'
assert_contains "$TEST_DIR/same.out" "impl quits; the watcher restarts it as $new"
assert_not_contains "$TEST_DIR/same.out" 'probe stdout'
[ "$(wc -l <"$SWAP_STATE/probes" | tr -d ' ')" = 1 ] || fail 'swap ran the CLI check more than once'
assert_contains "$SWAP_STATE/probes" '-p reply ok --max-turns 1'
[ ! -e "$SWAP_STATE/restarts" ] || fail 'swap restarted with watcher enabled'
[ "$(cat "$SWAP_STATE/peon_swap")" = "checking $new" ] || fail 'swap became done before watcher restart'
[ ! -e "$SWAP_STATE/job.log.pid" ] || fail 'completed check kept a stale process id'
[[ $(cat "$SWAP_STATE/peon_swap_pending") == waiting\ "$$":* ]] || fail 'waiting was not handed to live watcher PID'
if (SWAP_OWNER="$SWAP_STATE/job.log"; SWAP_JOB_PID=0; with_pane_delivery %1 swap_abort_locked %1); then fail 'exiting job cleared live watcher handoff'; fi
[ "$(cat "$SWAP_STATE/peon_swap")" = "checking $new" ] || fail 'handoff interruption changed queued status'
[ "$(cat "$SWAP_STATE/events")" = $'probe\ntrust\nquit' ] || fail 'swap did not probe, trust, then quit once'
[ "$(cat "$SWAP_STATE/trust_dirs")" = "$SWAP_STATE/project" ] || fail 'trust did not use target project'
[ "$(cat "$SWAP_STATE/trust_cwd")" = "$SWAP_STATE/project" ] || fail 'trust ran outside target project'
if (swap_reserve_locked %1 'codex --model overlapping' "$SWAP_STATE:%1"); then fail 'pending committed restart accepted another swap'; fi
(watch_restart swap-test %1 impl '' "$(cat "$SWAP_STATE/peon_launch")") >>"$TEST_DIR/same.out" 2>>"$TEST_DIR/same.err"
[ "$(cat "$SWAP_STATE/peon_swap")" = "done $new" ] || fail 'watcher success did not complete swap'
[ "$(cat "$SWAP_STATE/events")" = $'probe\ntrust\nquit\nready\nbrief' ] || fail 'done did not follow readiness and brief'

setup_swap trust-alias claude
ln -s "$SWAP_STATE/project" "$SWAP_STATE/project-alias"
printf '%s\n' "$SWAP_STATE/project-alias" >"$SWAP_STATE/peon_project_dir"
(run_swap impl 'codex --model trusted' swap-test) >"$TEST_DIR/trust-alias.out" 2>"$TEST_DIR/trust-alias.err"
[ "$(cat "$SWAP_STATE/trust_dirs")" = "$(printf '%s\n%s' "$SWAP_STATE/project" "$SWAP_STATE/project-alias")" ] || fail 'trust did not receive physical and logical target paths'
[ "$(cat "$SWAP_STATE/events")" = $'probe\ntrust\nquit\nready\nbrief' ] || fail 'trust alias called hook more than once'

setup_swap trust-failure claude
(SWAP_TRUST_FAIL=1; run_swap impl 'codex --model trusted' swap-test) >"$TEST_DIR/trust-failure.out" 2>"$TEST_DIR/trust-failure.err"
assert_contains "$TEST_DIR/trust-failure.err" 'peon-code: could not set codex project trust; continuing the swap'
[ "$(cat "$SWAP_STATE/peon_swap")" = 'done codex --model trusted' ] || fail 'trust failure stopped swap'
[ "$(cat "$SWAP_STATE/events")" = $'probe\ntrust\nquit\nready\nbrief' ] || fail 'trust failure prevented quit'

setup_swap cross 'claude --model old'
(run_swap impl 'codex --model new' swap-test defer) >"$TEST_DIR/cross.out" 2>"$TEST_DIR/cross.err"
assert_contains "$SWAP_STATE/brief.md" '[from codex impl %1]'
assert_contains "$SWAP_STATE/peon_launch" 'codex --model new --no-alt-screen '
assert_not_contains "$SWAP_STATE/peon_launch" '--settings'
[ "$(cat "$SWAP_STATE/peon_fresh")" = 1 ] || fail 'cross-CLI swap did not request fresh start'
[ "$(cat "$SWAP_STATE/quits")" = /exit ] || fail 'cross-CLI swap did not parse old Claude prompt'

for refusal in busy dialog copy; do
  setup_swap "quit-$refusal" 'claude --model old'
  printf 'old launch\n' >"$SWAP_STATE/peon_launch"
  printf 'weekly limit\n' >"$SWAP_STATE/peon_weekly"
  printf 'usage total\n' >"$SWAP_STATE/peon_usage"
  rm -f "$SWAP_STATE/peon_fresh"
  case $refusal in
    busy)
      printf 'typed text' >"$SWAP_STATE/box"
      printf '\n\n' >>"$SWAP_STATE/brief.md"
      cp "$SWAP_STATE/brief.md" "$SWAP_STATE/original.md" ;;
    dialog) printf '1\n' >"$SWAP_STATE/dialog" ;;
    copy) printf '1\n' >"$SWAP_STATE/in_mode" ;;
  esac
  if (run_swap impl 'codex --model refused' swap-test) >"$TEST_DIR/quit-$refusal.out" 2>"$TEST_DIR/quit-$refusal.err"; then fail "swap accepted $refusal quit"; fi
  cmp "$SWAP_STATE/original.md" "$SWAP_STATE/brief.md" || fail 'quit refusal changed byte-exact brief'
  [ "$(cat "$SWAP_STATE/peon_cmd")" = 'claude --model old' ] || fail 'quit refusal changed command'
  [ "$(cat "$SWAP_STATE/peon_bin")" = claude ] || fail 'quit refusal changed provider'
  [ "$(cat "$SWAP_STATE/peon_launch")" = 'old launch' ] || fail 'quit refusal changed launch'
  [ ! -e "$SWAP_STATE/peon_fresh" ] || fail 'quit refusal created an unset fresh option'
  [ "$(cat "$SWAP_STATE/peon_weekly")" = 'weekly limit' ] || fail 'quit refusal lost weekly limit'
  [ "$(cat "$SWAP_STATE/peon_usage")" = 'usage total' ] || fail 'quit refusal lost usage total'
  [ ! -e "$SWAP_STATE/quits" ] || fail 'quit refusal submitted exit'
done
assert_contains "$TEST_DIR/quit-busy.err" 'its input box holds typed text'
assert_contains "$TEST_DIR/quit-dialog.err" 'dialog or a menu'
assert_contains "$TEST_DIR/quit-copy.err" 'copy mode'

setup_swap roleless claude claude
printf 'You are claude, agent claude of peon-code session swap-test,\nStart every message with [from claude %%1]\npane %%1: claude (claude)\npane %%2: helper (claude)\n' >"$SWAP_STATE/brief.md"
(run_swap claude 'codex --model new' swap-test) >"$TEST_DIR/roleless.out" 2>"$TEST_DIR/roleless.err"
assert_contains "$SWAP_STATE/brief.md" 'You are claude (codex --model new), agent claude of peon-code session swap-test,'
assert_contains "$SWAP_STATE/brief.md" '[from codex claude %1]'
assert_contains "$SWAP_STATE/brief.md" 'pane %1: claude (codex --model new)'
assert_contains "$SWAP_STATE/brief.md" 'pane %2: helper (claude)'

# shellcheck disable=SC2031 # The changed-identity case exports only in its child.
for mode in shell self unsupported missing invalid no-path changed bad-directory unsupported-cli unchanged option-model option-effort; do
  setup_swap "$mode" claude
  case $mode in
    shell) printf 'bash\n' >"$SWAP_STATE/current" ;;
    self) ;;
    unsupported) printf 'copilot\n' >"$SWAP_STATE/peon_bin" ;;
    missing) : >"$SWAP_STATE/peon_cmd" ;;
    invalid) ;;
    no-path|changed) ;;
    bad-directory) printf '%s\n' "$SWAP_STATE/no-project" >"$SWAP_STATE/peon_project_dir" ;;
  esac
  if (
    [ "$mode" != self ] || TMUX_PANE=%1
    bin=codex model=new effort=-
    [ "$mode" != invalid ] || model='   '
    [ "$mode" != option-model ] || model=--help
    [ "$mode" != option-effort ] || effort=-xhigh
    [ "$mode" != unsupported-cli ] || bin=unknown-swap-agent
    if [ "$mode" = unchanged ]; then bin=-; model=-; fi
    if [ "$mode" = no-path ]; then
      # shellcheck disable=SC2317 # swap_run checks PATH through this stub.
      command() {
        if [ "$1" = -v ] && [ "${2:-}" = codex ]; then return 1; fi
        builtin command "$@"
      }
    fi
    [ "$mode" != changed ] || export PEON_EXPECTED_IDENTITY=old-pane
    cmd_swap impl "$bin" "$model" "$effort" swap-test
  ) >"$TEST_DIR/$mode.out" 2>"$TEST_DIR/$mode.err"; then
    fail "swap accepted $mode pane or command"
  fi
  assert_unchanged
  [ ! -e "$SWAP_STATE/probes" ] || fail 'rejected swap ran a pointless CLI check'
done
assert_contains "$TEST_DIR/shell.err" 'nothing to swap, launch it instead'
assert_contains "$TEST_DIR/self.err" 'calling pane'
assert_contains "$TEST_DIR/unsupported.err" 'quit it by hand'
assert_contains "$TEST_DIR/no-path.err" 'peon-code: codex is not on PATH'
assert_contains "$TEST_DIR/unsupported-cli.err" 'peon-code: swap does not know unknown-swap-agent'
assert_contains "$TEST_DIR/unchanged.err" 'swap needs a CLI, model, or effort change'
assert_contains "$TEST_DIR/changed.err" 'no swap: agent changed'
assert_contains "$TEST_DIR/bad-directory.err" 'no accessible project directory'

test_probe_builders() {
  [ "$(cli_call claude probe_command claude ' --model test')" = 'claude --model test -p "reply ok" --max-turns 1' ] || fail 'Claude probe command changed'
  [ "$(cli_call codex probe_command codex ' --model test')" = 'codex --model test exec "reply ok"' ] || fail 'Codex probe command changed'
  if cli_call unknown-swap-agent probe_command unknown-swap-agent ''; then fail 'unknown CLI has a probe'; fi
}
test_probe_builders

# shellcheck disable=SC2030 # Each child selects its own fake CLI response.
for mode in fail blank; do
  setup_swap "probe-$mode" claude
  if (export SWAP_PROBE_MODE="$mode"; run_swap impl 'claude --model bad' swap-test) >"$TEST_DIR/probe-$mode.out" 2>"$TEST_DIR/probe-$mode.err"; then
    fail "swap accepted the $mode CLI check"
  fi
  assert_unchanged
  [ "$(wc -l <"$SWAP_STATE/probes" | tr -d ' ')" = 1 ] || fail 'failed check ran more than once'
  [ ! -e "$SWAP_STATE/trust_dirs" ] || fail 'failed probe trusted project'
  case $mode in
    fail) detail='model is not available' ;;
    blank) detail='exit status 7' ;;
  esac
  [ "$(cat "$SWAP_STATE/peon_swap")" = "failed: $detail" ] || fail 'failed check did not store the raw final error'
done
assert_contains "$TEST_DIR/probe-fail.err" 'peon-code: claude --model bad failed its check: model is not available'
assert_contains "$TEST_DIR/probe-blank.err" 'peon-code: claude --model bad failed its check: exit status 7'

setup_swap probe-unknown claude
(run_swap impl 'unknown-swap-agent --model new' swap-test) >"$TEST_DIR/probe-unknown.out" 2>"$TEST_DIR/probe-unknown.err"
assert_contains "$TEST_DIR/probe-unknown.out" 'peon-code: no check for unknown-swap-agent; swapping on the PATH check only'
[ ! -e "$SWAP_STATE/probes" ] || fail 'unknown CLI was probed'
[ "$(cat "$SWAP_STATE/quits")" = /exit ] || fail 'PATH-only swap did not quit'

# shellcheck disable=SC2030,SC2031 # Each child selects its own fake CLI response.
for isolation in scope child; do
  if [ "$isolation" = scope ] && ! command -v setsid >/dev/null 2>&1; then continue; fi
  setup_swap "probe-timeout-$isolation" claude
  if (
    export SWAP_PROBE_MODE=hang
    if [ "$isolation" = child ]; then
      # shellcheck disable=SC2317 # swap_check calls this command lookup stub.
      command() {
        if [ "$1" = -v ] && [ "${2:-}" = setsid ]; then return 1; fi
        builtin command "$@"
      }
    fi
    sleep() {
      if [ "$1" = 0.1 ] && [ ! -s "$SWAP_STATE/probe_pid" ]; then command sleep 0.1; fi
    }
    kill() {
      case $1 in -TERM|-KILL) printf '%s\n' "$*" >>"$SWAP_STATE/signals" ;; esac
      builtin kill "$@"
    }
    run_swap impl 'claude --model slow' swap-test
  ) >"$TEST_DIR/probe-timeout.out" 2>"$TEST_DIR/probe-timeout.err"; then
    fail 'swap accepted a timed-out CLI check'
  fi
  assert_unchanged
  assert_contains "$TEST_DIR/probe-timeout.err" 'failed its check: timed out after 60 seconds'
  [ "$(wc -l <"$SWAP_STATE/probes" | tr -d ' ')" = 1 ] || fail 'timed-out check ran more than once'
  if kill -0 "$(cat "$SWAP_STATE/probe_pid")" 2>/dev/null; then fail 'timed-out CLI survived'; fi
  target=$(sed -n 's/^-KILL -- //p' "$SWAP_STATE/signals")
  [ -n "$target" ] || fail 'timed-out CLI never received KILL'
  if kill -0 -- "$target" 2>/dev/null; then fail 'timed-out probe survived'; fi
done

setup_swap probe-interrupted claude
# shellcheck disable=SC2030,SC2031 # This child selects its own fake CLI response.
(
  export SWAP_PROBE_MODE=hang
  trap ':' TERM
  before=$(trap -p TERM)
  sleep() {
    if [ "$1" = 0.1 ] && [ -s "$SWAP_STATE/probe_pid" ] && [ ! -s "$SWAP_STATE/check_pid" ]; then
      # $$ names the original shell in a Bash subshell; its child sees the actual PID.
      printf '%s\n' "$(exec sh -c 'echo "$PPID"')" >"$SWAP_STATE/check_pid"
      printf '%s\n' "$dir" >"$SWAP_STATE/check_dir"
    fi
    command sleep "$1"
  }
  rc=0
  run_swap impl 'claude --model interrupted' swap-test || rc=$?
  [ "$rc" = 143 ] || fail 'interrupted CLI check lost its exit status'
  [ "$(trap -p TERM)" = "$before" ] || fail 'CLI check changed the caller TERM trap'
  exit "$rc"
) >"$TEST_DIR/probe-interrupted.out" 2>"$TEST_DIR/probe-interrupted.err" &
swap_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ ! -s "$SWAP_STATE/check_pid" ] || break
  command sleep 0.1
done
[ -s "$SWAP_STATE/check_pid" ] || fail 'CLI check did not expose its own PID'
kill -TERM "$(cat "$SWAP_STATE/check_pid")"
rc=0
wait "$swap_pid" || rc=$?
[ "$rc" = 143 ] || fail 'swap continued after an interrupted CLI check'
assert_unchanged
if kill -0 "$(cat "$SWAP_STATE/probe_pid")" 2>/dev/null; then fail 'interrupted CLI probe survived'; fi
[ ! -d "$(cat "$SWAP_STATE/check_dir")" ] || fail 'interrupted check kept its temporary files'

setup_swap manual claude
printf '0\n' >"$SWAP_STATE/peon_restart"
# An older pane has no project option; use its current path instead.
: >"$SWAP_STATE/peon_project_dir"
SWAP_TRANSCRIPT="$SWAP_STATE/old-thread.jsonl"
: >"$SWAP_TRANSCRIPT"
caller_dir="$TEST_DIR/caller"
mkdir -p "$caller_dir"
(
  cd "$caller_dir"
  before=$PWD
  run_swap impl 'claude --model new' swap-test
  [ "$PWD" = "$before" ] || fail 'swap changed the caller directory'
) >"$TEST_DIR/manual.out" 2>"$TEST_DIR/manual.err"
[ "$(cat "$SWAP_STATE/restarts")" = restart ] || fail 'manual swap did not restart exactly once'
[ "$(cat "$SWAP_STATE/lookup_cwd")" = "$SWAP_STATE/project" ] || fail 'manual restart looked for transcripts outside the target project'
[ "$(cat "$SWAP_STATE/probe_cwd")" = "$SWAP_STATE/project" ] || fail 'CLI check ran outside the target project'
assert_contains "$SWAP_STATE/launches" 'claude --resume old-thread --model new'
assert_contains "$SWAP_STATE/brief.md" '[from claude impl %1]'
assert_not_contains "$SWAP_STATE/brief.md" '[from claude --model'

setup_swap relative claude
cp "$bin_dir/unknown-swap-agent" "$SWAP_STATE/project/relative-swap-agent"
(
  cd "$caller_dir"
  before=$PWD
  run_swap impl './relative-swap-agent --model new' swap-test
  [ "$PWD" = "$before" ] || fail 'relative command swap changed the caller directory'
) >"$TEST_DIR/relative.out" 2>"$TEST_DIR/relative.err"
assert_contains "$SWAP_STATE/peon_cmd" './relative-swap-agent --model new'

setup_swap roundtrip 'claude --model old'
(run_swap impl 'codex --model next' swap-test) >"$TEST_DIR/roundtrip.out" 2>"$TEST_DIR/roundtrip.err"
printf 'node\n' >"$SWAP_STATE/current"
printf 'codex\n' >"$SWAP_STATE/screen_bin"
printf '0\n' >"$SWAP_STATE/peon_restart"
SWAP_TRANSCRIPT="$SWAP_STATE/old-claude-thread.jsonl"
: >"$SWAP_TRANSCRIPT"
(run_swap impl 'claude --model final' swap-test) >>"$TEST_DIR/roundtrip.out" 2>>"$TEST_DIR/roundtrip.err"
[ ! -e "$SWAP_STATE/lookups" ] || fail 'cross-CLI roundtrip looked up an old thread'
assert_contains "$SWAP_STATE/launches" 'claude --model final'
assert_not_contains "$SWAP_STATE/launches" '--resume'
[ "$(cat "$SWAP_STATE/peon_fresh")" = 0 ] || fail 'successful fresh restart kept its flag'

setup_swap failed 'claude --model old'
printf '0\n' >"$SWAP_STATE/peon_restart"
if (SWAP_READY=0; run_swap impl 'codex --model new' swap-test) >"$TEST_DIR/failed.out" 2>"$TEST_DIR/failed.err"; then
  fail 'swap accepted a failed restart'
fi
[ "$(cat "$SWAP_STATE/peon_fresh")" = 1 ] || fail 'failed fresh restart lost its flag'
printf 'bash\n' >"$SWAP_STATE/current"
(watch_restart swap-test %1 impl '' "$(cat "$SWAP_STATE/peon_launch")") >"$TEST_DIR/retry.out" 2>"$TEST_DIR/retry.err"
[ "$(cat "$SWAP_STATE/peon_fresh")" = 0 ] || fail 'fresh retry did not clear its flag'

setup_swap dispatch 'codex --model keep -c model_reasoning_effort=low'
dispatch_command='codex -c model_reasoning_effort=low --model dispatch'
SWAP_PROBE_MODE=slow "$job_root/peon-code.sh" swap impl - dispatch - swap-test >"$TEST_DIR/dispatch.out" 2>"$TEST_DIR/dispatch.err"
assert_contains "$TEST_DIR/dispatch.out" "peon-code: checking $dispatch_command for impl; the swap follows when it passes"
for ((attempt = 0; attempt < 100; attempt++)); do
  [ ! -s "$SWAP_STATE/probe_pid" ] || break
  command sleep 0.1
done
[ -s "$SWAP_STATE/probe_pid" ] || fail 'detached probe never started'
assert_unchanged
[ "$(cat "$SWAP_STATE/peon_swap")" = "checking $dispatch_command" ] || fail 'slow probe did not keep checking'
if "$job_root/peon-code.sh" swap impl claude duplicate - swap-test >"$TEST_DIR/duplicate.out" 2>"$TEST_DIR/duplicate.err"; then
  fail 'second swap was accepted while checking'
fi
assert_contains "$TEST_DIR/duplicate.err" 'already checking'
assert_unchanged
# The already composed command must not pick up a later metadata change.
printf 'codex --model changed -c model_reasoning_effort=high\n' >"$SWAP_STATE/peon_cmd"
: >"$SWAP_STATE/release"
for ((attempt = 0; attempt < 100; attempt++)); do
  if [ -s "$SWAP_STATE/peon_swap_pending" ] &&
     [[ $(cat "$SWAP_STATE/peon_swap_pending") == waiting\ *\ "$dispatch_command" ]]; then
    watch_restart swap-test %1 impl '' "$(cat "$SWAP_STATE/peon_launch")" || true
  fi
  [ "$(cat "$SWAP_STATE/peon_swap")" != "done $dispatch_command" ] || break
  command sleep 0.1
done
[ "$(cat "$SWAP_STATE/peon_swap")" = "done $dispatch_command" ] || fail 'detached swap did not finish'
[ "$(cat "$SWAP_STATE/peon_cmd")" = "$dispatch_command" ] || fail 'detached job recomposed preserved fields after metadata changed'
[ "$(cat "$SWAP_STATE/quits")" = /exit ] || fail 'detached swap did not quit once'
if kill -0 "$(cat "$SWAP_STATE/probe_pid")" 2>/dev/null; then fail 'completed detached probe survived'; fi

setup_swap stale-job claude
# shellcheck disable=SC2030,SC2031 # This child selects its own fake CLI response.
if (export SWAP_PROBE_MODE=changed; run_swap impl 'codex --model stale' swap-test) >"$TEST_DIR/stale.out" 2>"$TEST_DIR/stale.err"; then
  fail 'swap applied to a replacement pane'
fi
assert_unchanged
[ "$(cat "$SWAP_STATE/peon_swap")" = 'checking codex --model stale' ] || fail 'stale job changed replacement pane status'

setup_swap scope-startup claude
cat >"$bin_dir/systemd-run" <<'FAILED_SCOPE'
#!/bin/sh
for last do :; done
[ "$last" != true ] || exit 0
printf 'scope start failed\n' >&2
exit 1
FAILED_SCOPE
if (swap_reserve_locked %1 'codex --model scope' "$SWAP_STATE:%1" "$SWAP_STATE/job.log" &&
    swap_job %1 "$SWAP_STATE:%1" "$SWAP_STATE/job.log" impl 'codex --model scope' swap-test) >"$TEST_DIR/scope.out" 2>"$TEST_DIR/scope.err"; then
  fail 'swap accepted a failed scope start'
fi
[ "$(cat "$SWAP_STATE/peon_swap")" = 'failed: could not start the swap job' ] || fail 'scope startup failure kept checking'
assert_unchanged
[ ! -e "$SWAP_STATE/probes" ] || fail 'failed scope startup ran a probe'
printf '#!/bin/sh\nexit 1\n' >"$bin_dir/systemd-run"

setup_swap simultaneous claude
with_pane_delivery %1 swap_reserve_locked %1 'codex --model one' "$SWAP_STATE:%1" >"$TEST_DIR/reserve1.out" 2>&1 &
first=$!
with_pane_delivery %1 swap_reserve_locked %1 'codex --model two' "$SWAP_STATE:%1" >"$TEST_DIR/reserve2.out" 2>&1 &
second=$!
first_rc=0 second_rc=0
wait "$first" || first_rc=$?
wait "$second" || second_rc=$?
[ "$((first_rc + second_rc))" = 1 ] || fail 'concurrent reservations did not select exactly one job'
assert_unchanged

setup_swap detached-interrupted claude
# shellcheck disable=SC2031 # This test sets the response for its detached job.
export SWAP_PROBE_MODE=hang
cmd_swap impl codex interrupted - swap-test >"$TEST_DIR/detached-interrupted.out" 2>"$TEST_DIR/detached-interrupted.err"
job_pid=$!
unset SWAP_PROBE_MODE
for ((attempt = 0; attempt < 100; attempt++)); do
  [ ! -s "$SWAP_STATE/probe_pid" ] || break
  command sleep 0.1
done
[ -s "$SWAP_STATE/probe_pid" ] || fail 'interrupt test probe never started'
kill -TERM "$job_pid"
rc=0
wait "$job_pid" || rc=$?
[ "$rc" = 143 ] || fail 'detached job lost its interruption status'
for ((attempt = 0; attempt < 30; attempt++)); do
  kill -0 "$(cat "$SWAP_STATE/probe_pid")" 2>/dev/null || break
  command sleep 0.1
done
if kill -0 "$(cat "$SWAP_STATE/probe_pid")" 2>/dev/null; then fail 'interrupted detached probe survived'; fi
[ "$(cat "$SWAP_STATE/peon_swap")" = 'failed: swap job interrupted' ] || fail 'interrupted detached job kept checking'
assert_unchanged

setup_swap lost-restart-claim claude
printf '%s\n' "$SWAP_STATE:%1" >"$SWAP_STATE/peon_swap_identity"
printf 'waiting %s:%s claude --model next\n' "$$" "$(date +%s)" >"$SWAP_STATE/peon_swap_pending"
printf 'owner\n' >"$SWAP_STATE/peon_swap_owner"
printf 'checking claude --model next\n' >"$SWAP_STATE/peon_swap"
if (
  eval "$(declare -f watch_launch_locked | sed '1s/watch_launch_locked/real_watch_launch_locked/')"
  # shellcheck disable=SC2317 # watch_restart dispatches this claim-race stub.
  watch_launch_locked() {
    tmux set -pt %1 @peon_swap_pending 'running winner:1 claude --model next'
    real_watch_launch_locked "$@"
  }
  printf 'bash\n' >"$SWAP_STATE/current"
  watch_restart swap-test %1 impl '' 'claude --model next'
) >"$TEST_DIR/lost-claim.out" 2>"$TEST_DIR/lost-claim.err"; then fail 'restart accepted a lost claim'; fi
[ "$(cat "$SWAP_STATE/peon_swap_pending")" = 'running winner:1 claude --model next' ] || fail 'losing caller cleared winning restart claim'
[ "$(cat "$SWAP_STATE/peon_swap")" = 'checking claude --model next' ] || fail 'losing caller published failure over active winner'
[ ! -e "$SWAP_STATE/launches" ] || fail 'losing caller launched an agent'

setup_swap stale-restart-scan claude
if (watch_restart swap-test %1 impl '' 'claude --model next') >"$TEST_DIR/stale-scan.out" 2>"$TEST_DIR/stale-scan.err"; then fail 'stale restart scan accepted a live agent'; fi
[ ! -e "$SWAP_STATE/launches" ] || fail 'stale restart scan pasted into a live agent'

setup_swap dead-running claude
printf '%s\n' "$SWAP_STATE:%1" >"$SWAP_STATE/peon_swap_identity"
printf 'owner\n' >"$SWAP_STATE/peon_swap_owner"
printf 'checking claude --model next\n' >"$SWAP_STATE/peon_swap"
printf 'running %s:1 claude --model next\n' "$$" >"$SWAP_STATE/peon_swap_pending"
if (with_pane_delivery %1 swap_reserve_locked %1 'codex --model retry' "$SWAP_STATE:%1"); then fail 'live running claimant did not block swap'; fi
(exit 0) &
dead_pid=$!
wait "$dead_pid"
printf 'running %s:1 claude --model next\n' "$dead_pid" >"$SWAP_STATE/peon_swap_pending"
(with_pane_delivery %1 watch_swap_reap_locked %1)
[ "$(cat "$SWAP_STATE/peon_swap")" = 'failed: swap restart job stopped' ] || fail 'dead running claimant kept checking'
[ ! -e "$SWAP_STATE/peon_swap_pending" ] || fail 'dead running claimant kept its marker'
(with_pane_delivery %1 swap_reserve_locked %1 'codex --model retry' "$SWAP_STATE:%1") || fail 'dead running claimant prevented retry'

for isolation in scope plain fallback; do
  setup_swap "killed-job-$isolation" codex
  if [ "$isolation" = scope ]; then
    cat >"$bin_dir/systemd-run" <<'FAKE_SCOPE'
#!/bin/sh
while [ "$1" != -- ]; do shift; done
shift
exec "$@"
FAKE_SCOPE
  else printf '#!/bin/sh\nexit 1\n' >"$bin_dir/systemd-run"; fi
  (
    if [ "$isolation" = fallback ]; then
      # shellcheck disable=SC2317 # The launch helper checks this lookup stub.
      command() {
        if [ "$1" = -v ] && [ "${2:-}" = setsid ]; then return 1; fi
        builtin command "$@"
      }
    fi
    export SWAP_PROBE_MODE=slow
    cmd_swap impl - killed - swap-test
    printf '%s\n' "$!" >"$SWAP_STATE/launcher_pid"
  ) >"$TEST_DIR/killed-$isolation.out" 2>"$TEST_DIR/killed-$isolation.err"
  for ((attempt = 0; attempt < 100; attempt++)); do
    if [ -s "$SWAP_STATE/probe_pid" ] && [ -s "$SWAP_STATE/peon_swap_pid" ]; then break; fi
    command sleep 0.1
  done
  if [ ! -s "$SWAP_STATE/probe_pid" ] || [ ! -s "$SWAP_STATE/peon_swap_pid" ]; then
    fail 'killed-job fixture never became live'
  fi
  live_pid=$(cat "$SWAP_STATE/peon_swap_pid")
  if (cmd_swap impl - duplicate - swap-test) >"$TEST_DIR/killed-live.out" 2>"$TEST_DIR/killed-live.err"; then fail 'live detached job accepted another swap'; fi
  assert_contains "$TEST_DIR/killed-live.err" 'already checking'
  old_probe=$(cat "$SWAP_STATE/probe_pid")
  kill -KILL "$live_pid"
  for ((attempt = 0; attempt < 100; attempt++)); do
    kill -0 "$live_pid" 2>/dev/null || break
    command sleep 0.1
  done
  (run_fields impl - retry - swap-test) >"$TEST_DIR/killed-retry.out" 2>"$TEST_DIR/killed-retry.err" || fail 'killed detached job prevented retry'
  [ "$(cat "$SWAP_STATE/peon_swap")" = 'done codex --model retry' ] || fail 'retry after killed job did not finish'
  : >"$SWAP_STATE/release"
  for ((attempt = 0; attempt < 100; attempt++)); do
    kill -0 "$old_probe" 2>/dev/null || break
    command sleep 0.1
  done
  if kill -0 "$old_probe" 2>/dev/null; then fail 'released orphan probe survived'; fi
  [ "$(cat "$SWAP_STATE/peon_cmd")" = 'codex --model retry' ] || fail 'old killed job overwrote new command'
  [ "$(cat "$SWAP_STATE/peon_swap")" = 'done codex --model retry' ] || fail 'old killed job overwrote new status'
done
printf '#!/bin/sh\nexit 1\n' >"$bin_dir/systemd-run"

setup_swap missing-startup-pid claude
(with_pane_delivery %1 swap_reserve_locked %1 'codex --model stale' "$SWAP_STATE:%1")
if (with_pane_delivery %1 swap_reserve_locked %1 'codex --model retry' "$SWAP_STATE:%1"); then fail 'startup grace allowed a second job'; fi
printf '0\n' >"$SWAP_STATE/peon_swap_started"
(with_pane_delivery %1 swap_reserve_locked %1 'codex --model retry' "$SWAP_STATE:%1") || fail 'expired startup grace prevented retry'

"$job_root/peon-code.sh" -h >"$TEST_DIR/swap-help.out"
assert_contains "$TEST_DIR/swap-help.out" 'swap <name> <cli|-> <model|-> <effort|->'
assert_contains "$TEST_DIR/swap-help.out" 'restart dead agents'
setup_swap quit-timeout claude
printf '0\n' >"$SWAP_STATE/peon_restart"
printf 'old launch\n' >"$SWAP_STATE/peon_launch"
printf 'weekly limit\n' >"$SWAP_STATE/peon_weekly"
rm -f "$SWAP_STATE/peon_fresh" "$SWAP_STATE/peon_usage"
printf '\n\n' >>"$SWAP_STATE/brief.md"
cp "$SWAP_STATE/brief.md" "$SWAP_STATE/original.md"
: >"$SWAP_STATE/no_quit"
if (run_swap impl 'codex --model timeout' swap-test) >"$TEST_DIR/quit-timeout.out" 2>"$TEST_DIR/quit-timeout.err"; then fail 'swap accepted an agent that never quit'; fi
cmp "$SWAP_STATE/original.md" "$SWAP_STATE/brief.md" || fail 'quit timeout changed byte-exact brief'
[ "$(cat "$SWAP_STATE/peon_cmd")" = claude ] || fail 'quit timeout kept new command'
[ "$(cat "$SWAP_STATE/peon_bin")" = claude ] || fail 'quit timeout kept new CLI'
[ "$(cat "$SWAP_STATE/peon_launch")" = 'old launch' ] || fail 'quit timeout lost old launch'
[ "$(cat "$SWAP_STATE/peon_weekly")" = 'weekly limit' ] || fail 'quit timeout lost weekly limit'
[ ! -e "$SWAP_STATE/peon_fresh" ] || fail 'quit timeout changed unset fresh option'
[ ! -e "$SWAP_STATE/peon_usage" ] || fail 'quit timeout changed unset usage option'
[ ! -e "$SWAP_STATE/peon_swap_pending" ] || fail 'quit timeout prevented retry'
rm -f "$SWAP_STATE/no_quit"
(run_swap impl 'codex --model retry' swap-test) >"$TEST_DIR/quit-timeout-retry.out" 2>"$TEST_DIR/quit-timeout-retry.err" || fail 'quit timeout retry failed'
[ ! -e "$SWAP_STATE/peon_weekly" ] || fail 'swap kept old provider weekly limit'
[ ! -e "$SWAP_STATE/peon_usage" ] || fail 'swap kept old provider usage'

setup_swap dead-waiting claude
printf '%s\n' "$SWAP_STATE:%1" >"$SWAP_STATE/peon_swap_identity"
printf 'owner\n' >"$SWAP_STATE/peon_swap_owner"
printf 'checking claude --model next\n' >"$SWAP_STATE/peon_swap"
(exit 0) &
dead_pid=$!
wait "$dead_pid"
printf 'waiting %s:%s claude --model next\n' "$dead_pid" "$(date +%s)" >"$SWAP_STATE/peon_swap_pending"
(with_pane_delivery %1 swap_reserve_locked %1 'codex --model retry' "$SWAP_STATE:%1") || fail 'dead waiting job prevented retry'

for signal in TERM KILL; do
  setup_swap "waiting-interrupted-$signal" claude
  printf 'old launch\n' >"$SWAP_STATE/peon_launch"
  printf 'weekly\n' >"$SWAP_STATE/peon_weekly"
  rm -f "$SWAP_STATE/peon_fresh" "$SWAP_STATE/peon_usage"
  printf '\n\n' >>"$SWAP_STATE/brief.md"
  cp "$SWAP_STATE/brief.md" "$SWAP_STATE/original.md"
  : >"$SWAP_STATE/no_quit"
  cmd_swap impl codex interrupted - swap-test >"$TEST_DIR/waiting-$signal.out" 2>"$TEST_DIR/waiting-$signal.err"
  launcher=$!
  for ((attempt = 0; attempt < 100; attempt++)); do
    [ ! -s "$SWAP_STATE/quits" ] || break
    command sleep 0.1
  done
  [ -s "$SWAP_STATE/quits" ] || fail 'waiting interruption never submitted quit'
  claim=$(cat "$SWAP_STATE/peon_swap_pending")
  [[ $claim == waiting\ [0-9]*:[0-9]*\ codex\ --model\ interrupted ]] || fail 'waiting marker missed PID or timestamp'
  live_pid=$(cat "$SWAP_STATE/peon_swap_pid")
  kill "-$signal" "$live_pid"
  wait "$launcher" 2>/dev/null || true
  if [ "$signal" = KILL ]; then
    with_pane_delivery %1 watch_swap_reap_locked %1 || fail 'killed waiting job was not reaped'
  fi
  cmp "$SWAP_STATE/original.md" "$SWAP_STATE/brief.md" || fail 'waiting interruption changed byte-exact brief'
  [ "$(cat "$SWAP_STATE/peon_cmd")" = claude ] || fail 'waiting interruption kept new command'
  [ "$(cat "$SWAP_STATE/peon_bin")" = claude ] || fail 'waiting interruption kept new CLI'
  [ "$(cat "$SWAP_STATE/peon_launch")" = 'old launch' ] || fail 'waiting interruption lost old launch'
  [ "$(cat "$SWAP_STATE/peon_weekly")" = weekly ] || fail 'waiting interruption lost weekly limit'
  [ ! -e "$SWAP_STATE/peon_fresh" ] || fail 'waiting interruption changed unset fresh option'
  [ ! -e "$SWAP_STATE/peon_usage" ] || fail 'waiting interruption changed unset usage option'
  [ ! -e "$SWAP_STATE/peon_swap_pending" ] || fail 'waiting interruption kept reservation'
  rm -f "$SWAP_STATE/no_quit"
  (run_swap impl 'codex --model retry' swap-test) >"$TEST_DIR/waiting-retry-$signal.out" 2>"$TEST_DIR/waiting-retry-$signal.err" || fail 'interrupted waiting job prevented retry'
done

setup_swap wrong-pid-owner claude
printf 'checking codex --model old\n' >"$SWAP_STATE/peon_swap"
printf '%s\n' "$$" >"$SWAP_STATE/peon_swap_pid"
printf 'different-job-token\n' >"$SWAP_STATE/peon_swap_owner"
printf '0\n' >"$SWAP_STATE/peon_swap_started"
(with_pane_delivery %1 swap_reserve_locked %1 'codex --model retry' "$SWAP_STATE:%1") || fail 'reused PID with different owner prevented retry'

setup_swap wrong-running-owner claude
printf '%s\n' "$SWAP_STATE:%1" >"$SWAP_STATE/peon_swap_identity"
printf 'different-job-token\n' >"$SWAP_STATE/peon_swap_owner"
printf '%s\n' "$dead_pid" >"$SWAP_STATE/peon_watch_pid"
printf 'running %s:%s:1 claude --model next\n' "$$" "$(date +%s)" >"$SWAP_STATE/peon_swap_pending"
(with_pane_delivery %1 watch_swap_reap_locked %1) || fail 'reused running PID with different owner kept reservation'
kill -0 "$$" || fail 'stale running recovery signaled another process'
[ ! -e "$SWAP_STATE/peon_swap_pending" ] || fail 'stale running owner kept pending'

setup_swap pre-pending-commit 'claude --model old --effort high --keep value'
printf 'old launch\n' >"$SWAP_STATE/peon_launch"
printf 'weekly\n' >"$SWAP_STATE/peon_weekly"
rm -f "$SWAP_STATE/peon_fresh" "$SWAP_STATE/peon_usage"
(
  id=%1 name=impl command='codex --model abandoned' BIN=codex LAUNCH='codex --model abandoned' fresh=0
  old_command='claude --model old --effort high --keep value' old_bin=claude
  brief="$SWAP_STATE/brief.md" SWAP_OWNER="$SWAP_STATE/partial-job.log"
  PEON_EXPECTED_IDENTITY="$SWAP_STATE:%1"
  actual_pid=$(exec sh -c 'echo "$PPID"')
  swap_reserve_locked %1 "$command" "$PEON_EXPECTED_IDENTITY" "$SWAP_OWNER"
  command tmux set -pt %1 @peon_swap_pid "$actual_pid"
  tmux() {
    if [ "$1" = set ] && [ "${4:-}" = @peon_swap_pending ]; then
      kill -KILL "$actual_pid"
    fi
    command tmux "$@"
  }
  swap_commit_locked
) &
partial_pid=$!
wait "$partial_pid" 2>/dev/null || true
[ "$(cat "$SWAP_STATE/peon_bin")" = codex ] || fail 'partial commit fixture did not update CLI'
[ -s "$SWAP_STATE/peon_swap_backup" ] || fail 'partial commit fixture lost backup'
[ ! -e "$SWAP_STATE/peon_swap_pending" ] || fail 'partial commit fixture reached pending'
(run_fields impl - retry - swap-test) >"$TEST_DIR/pre-pending.out" 2>"$TEST_DIR/pre-pending.err" || fail 'partial commit prevented public retry'
[ "$(cat "$SWAP_STATE/peon_cmd")" = 'claude --effort high --keep value --model retry' ] || fail 'retry composed from abandoned CLI or args'
assert_contains "$SWAP_STATE/brief.md" 'You are impl (claude --effort high --keep value --model retry),'

setup_swap absent-watcher claude
printf '%s\n' "$dead_pid" >"$SWAP_STATE/peon_watch_pid"
if (run_swap impl 'codex --model no-watcher' swap-test defer) >"$TEST_DIR/no-watcher.out" 2>"$TEST_DIR/no-watcher.err"; then fail 'absent watcher kept a pending swap'; fi
[ "$(cat "$SWAP_STATE/peon_swap")" = 'failed: no live watcher claimed the swap' ] || fail 'absent watcher missed explicit failure'
[ "$(cat "$SWAP_STATE/peon_cmd")" = 'codex --model no-watcher' ] || fail 'confirmed quit restored old command'
[ ! -e "$SWAP_STATE/peon_swap_pending" ] || fail 'absent watcher kept stale reservation'
echo 'swap: PASS'
