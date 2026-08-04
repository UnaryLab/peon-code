#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/peon-code-test.XXXXXX")

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local file=$1 text=$2
  grep -Fq -- "$text" "$file" || fail "$file does not contain: $text"
}

assert_not_contains() {
  local file=$1 text=$2
  if grep -Fq -- "$text" "$file"; then
    fail "$file contains: $text"
  fi
}

test_install_guard() {
  local home_dir="$TEST_DIR/home-install" bin_dir="$TEST_DIR/bin-install"
  mkdir -p "$home_dir" "$bin_dir"
  printf 'keep me\n' >"$bin_dir/peon-code"
  if HOME="$home_dir" "$ROOT/install.sh" "$bin_dir" >"$TEST_DIR/install.out" 2>"$TEST_DIR/install.err"; then
    fail "install replaced an existing command"
  fi
  [ "$(cat "$bin_dir/peon-code")" = "keep me" ] || fail "install changed an existing command"

  bin_dir="$TEST_DIR/bin-dangling"
  mkdir -p "$bin_dir"
  ln -s "$TEST_DIR/missing-foreign-command" "$bin_dir/peon-code"
  if HOME="$home_dir" "$ROOT/install.sh" "$bin_dir" >"$TEST_DIR/install-dangling.out" 2>"$TEST_DIR/install-dangling.err"; then
    fail "install replaced a foreign dangling symlink"
  fi
  [ "$(readlink "$bin_dir/peon-code")" = "$TEST_DIR/missing-foreign-command" ] ||
    fail "install changed a foreign dangling symlink"

  bin_dir="$TEST_DIR/bin-new"
  mkdir -p "$bin_dir"
  HOME="$home_dir" "$ROOT/install.sh" "$bin_dir" >"$TEST_DIR/install-new.out"
  HOME="$home_dir" "$ROOT/install.sh" "$bin_dir" >"$TEST_DIR/install-again.out"
  [ "$(readlink "$bin_dir/peon-code")" = "$ROOT/peon-code.sh" ] ||
    fail "install did not create the expected symlink"
  (
    cd "$TEST_DIR"
    HOME="$home_dir" "$bin_dir/peon-code" -h
  ) >"$TEST_DIR/installed-help.out"
  assert_contains "$TEST_DIR/installed-help.out" "peon-code.sh [-c file]"
}

make_fake_commands() {
  local bin_dir="$TEST_DIR/fake-bin"
  mkdir -p "$bin_dir"
  cat >"$bin_dir/tmux" <<'FAKE_TMUX'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"$FAKE_TMUX_LOG"
case ${1:-} in
  set|set-option)
    case " $* " in
      *" -t ="*) exit 2 ;;
    esac
    ;;
  split-window|select-layout|list-panes)
    case " $* " in
      *" -t ="*":agents "*) exit 2 ;;
    esac
    ;;
esac
case ${1:-} in
  has-session)
    [ "${FAKE_TMUX_MODE:-}" != launch ]
    ;;
  show-options)
    case " $* " in
      *" -t ="*) exit 2 ;;
      *" @peon_brief "*) printf '%s\n' "${FAKE_TMUX_BRIEF:-}"; exit 0 ;;
    esac
    [ "${FAKE_TMUX_MODE:-}" = owned ] && printf '1\n'
    exit 0
    ;;
  list-panes)
    case "$*" in
      *'#{pane_id} #{pane_current_command} #{@peon_name}'*)
        printf '%%1 codex impl\n'
        ;;
      *'#{pane_id}'*)
        for ((p = 1; p <= ${FAKE_TMUX_PANES:-1}; p++)); do
          printf '%%%d\n' "$p"
        done
        ;;
      *'#{@peon_name}'*)
        [ "${FAKE_TMUX_MODE:-}" = legacy ] && printf 'impl\n'
        ;;
    esac
    ;;
  display)
    case "$*" in
      *cursor_y*) printf '1\n' ;;
      *) printf 'zsh\n' ;;
    esac
    ;;
  capture-pane)
    printf '%s\n' "${FAKE_TMUX_CAPTURE:-}"
    ;;
  load-buffer)
    content=$(cat)
    printf 'buffer-content:%s\n' "$content" >>"$FAKE_TMUX_LOG"
    exit "${FAKE_LOAD_BUFFER_EXIT:-0}"
    ;;
esac
FAKE_TMUX
  cat >"$bin_dir/sleep" <<'FAKE_SLEEP'
#!/usr/bin/env bash
exit 0
FAKE_SLEEP
  chmod +x "$bin_dir/tmux" "$bin_dir/sleep"
  printf '%s\n' "$bin_dir"
}

test_session_ownership() {
  local fake_bin=$1 log="$TEST_DIR/tmux-ownership.log" home_dir="$TEST_DIR/home-tmux"
  mkdir -p "$home_dir"

  if PATH="$fake_bin:$PATH" HOME="$home_dir" FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=foreign \
    "$ROOT/peon-code.sh" dismiss foreign >"$TEST_DIR/foreign.out" 2>"$TEST_DIR/foreign.err"; then
    fail "dismiss accepted a foreign session"
  fi
  assert_contains "$TEST_DIR/foreign.err" "session foreign was not created by peon-code"
  if grep -Fq "kill-session" "$log"; then
    fail "dismiss killed a foreign session"
  fi

  : >"$log"
  PATH="$fake_bin:$PATH" HOME="$home_dir" FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=owned \
    "$ROOT/peon-code.sh" dismiss owned >"$TEST_DIR/owned.out"
  assert_contains "$log" "kill-session -t =owned"

  : >"$log"
  if PATH="$fake_bin:$PATH" HOME="$home_dir" FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=legacy \
    "$ROOT/peon-code.sh" dismiss legacy >"$TEST_DIR/legacy.out" 2>"$TEST_DIR/legacy.err"; then
    fail "dismiss accepted an unmarked legacy session"
  fi
  assert_contains "$TEST_DIR/legacy.err" "session legacy was not created by peon-code"
  if grep -Fq "kill-session" "$log"; then
    fail "dismiss killed an unmarked legacy session"
  fi
}

test_unique_buffers_and_launch_failure() {
  local fake_bin=$1 log="$TEST_DIR/tmux-buffer.log" home_dir="$TEST_DIR/home-buffer"
  mkdir -p "$home_dir" "$TEST_DIR/work"

  PATH="$fake_bin:$PATH" HOME="$home_dir" FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=owned \
    "$ROOT/peon-code.sh" msg all hello owned >"$TEST_DIR/msg.out"
  grep -Eq 'load-buffer -b peon-code-[0-9]+-1 -' "$log" ||
    fail "msg did not use a unique tmux buffer"

  : >"$log"
  (
    cd "$TEST_DIR/work"
    PATH="$fake_bin:$PATH" HOME="$home_dir" TMPDIR="$TEST_DIR" \
      FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=launch \
      "$ROOT/peon-code.sh" launch ./missing-agent
  ) >"$TEST_DIR/launch.out" 2>"$TEST_DIR/launch.err" &&
    fail "a launch with a dead agent succeeded"
  assert_contains "$TEST_DIR/launch.err" "agents failed to start; killed session launch: ./missing-agent"
  assert_contains "$log" "set-option -t launch @peon_code 1"
  assert_contains "$log" "list-panes -t launch:agents"
  assert_contains "$log" "kill-session -t =launch"
  assert_not_contains "$log" "set-option -t =launch"
  assert_not_contains "$TEST_DIR/launch.out" "session launch is ready"
  grep -Eq 'buffer-content:\./missing-agent .*/0\.md' "$log" ||
    fail "a numeric brief filename was not used"
  grep -Eq 'load-buffer -b peon-code-[0-9]+-1 -' "$log" ||
    fail "agent launch did not use a unique tmux buffer"
  if grep -Fq "/./missing-agent.md" "$TEST_DIR/launch.err"; then
    fail "a slash-containing command was used as a brief filename"
  fi
}

test_config_loading() {
  local fake_bin=$1 log="$TEST_DIR/tmux-config.log" home_dir="$TEST_DIR/home-config"
  local config_dir="$TEST_DIR/config" work_dir="$TEST_DIR/config-work" line brief_file
  mkdir -p "$home_dir" "$config_dir" "$work_dir"
  printf 'Keep changes focused.\n' >"$config_dir/custom.md"
  printf 'boss ./missing-agent ./custom.md\n' >"$config_dir/team.conf"

  (
    cd "$work_dir"
    PATH="$fake_bin:$PATH" HOME="$home_dir" TMPDIR="$TEST_DIR" \
      FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=launch \
      "$ROOT/peon-code.sh" -c "$config_dir/team.conf" config-test
  ) >"$TEST_DIR/config.out" 2>"$TEST_DIR/config.err" &&
    fail "a config launch with a dead agent succeeded"
  assert_contains "$TEST_DIR/config.err" "agents failed to start; killed session config-test: boss"
  assert_contains "$log" "kill-session -t =config-test"
  line=$(grep -F "buffer-content:" "$log" | tail -1)
  brief_file=${line#*"\$(cat "}
  brief_file=${brief_file%%')"'*}
  [ -n "$brief_file" ] || fail "the config launch did not record a brief file"
  assert_contains "$brief_file" "Keep changes focused."
  # The message prefix names the sender's CLI, its agent name, and its pane.
  assert_contains "$brief_file" "Start every message you send with [from ./missing-agent boss %"
  # Agents send through the subcommand, which checks and pastes in one run,
  # instead of the raw send-keys recipe that left a gap between the two.
  assert_contains "$brief_file" "$ROOT/peon-code.sh send <other-pane-id> - <<'PEON'"
  assert_contains "$brief_file" "3. Held sends: send makes the box check and the paste back to back"
  assert_not_contains "$brief_file" "tmux send-keys -t <other-pane-id> -l"
  # The message goes in on stdin, so nothing asks agents to mind their quoting.
  assert_not_contains "$brief_file" "Avoid single quotes"
}

# A tmux stand-in for send: the pane keeps its before-the-paste look until a
# paste is logged, then keeps it for FAKE_SETTLE more box reads before showing
# the box the message landed in. A box read is one cursor lookup followed by
# one capture, so the capture count is the number of polls send made.
SEND_LOG="$TEST_DIR/tmux-send.log"
make_send_bin() {
  local fake_bin=$1 bin_dir="$TEST_DIR/send-bin"
  mkdir -p "$bin_dir"
  cp "$fake_bin/sleep" "$bin_dir/sleep"
  cat >"$bin_dir/tmux" <<'FAKE_TMUX'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_TMUX_LOG"
state=before
grep -Fq paste-buffer "$FAKE_TMUX_LOG" && state=after
reads=0
[ -f "$FAKE_TMUX_LOG.reads" ] && reads=$(cat "$FAKE_TMUX_LOG.reads")
box=$FAKE_BOX
cursor=$FAKE_CURSOR
in_mode=${FAKE_IN_MODE:-0}
if [ "$state" = after ]; then
  in_mode=${FAKE_IN_MODE_AFTER:-0}
  if [ "$reads" -ge "${FAKE_SETTLE:-0}" ]; then
    box=$FAKE_BOX_AFTER
    cursor=$FAKE_CURSOR_AFTER
  fi
fi
case ${1:-} in
  display)
    case "$*" in
      *pane_current_command*) printf '%s\n' "${FAKE_CMD:-node}" ;;
      *pane_in_mode*) printf '%s\n' "$in_mode" ;;
      *cursor_x*) printf '%s\n' "$cursor" ;;
      *cursor_y*) printf '%s\n' "${cursor##* }" ;;
    esac
    ;;
  capture-pane)
    printf '%s\n' "$box"
    [ "$state" = after ] && printf '%s' "$((reads + 1))" >"$FAKE_TMUX_LOG.reads"
    ;;
  show-options) printf '%s\n' "${FAKE_PEON_NAME-impl}" ;;
  load-buffer) printf 'buffer-content:%s\n' "$(cat)" >>"$FAKE_TMUX_LOG" ;;
esac
exit 0
FAKE_TMUX
  chmod +x "$bin_dir/tmux"
  printf '%s\n' "$bin_dir"
}

reset_send_log() {
  : >"$SEND_LOG"
  rm -f "$SEND_LOG.reads"
}

# How many times send read the target's box.
send_captures() {
  grep -c '^capture-pane' "$SEND_LOG" || true
}

# One refused send. Arguments after the wanted message are the FAKE_ settings
# that put the pane in the state under test.
assert_send_refused() {
  local what=$1 want=$2 out="$TEST_DIR/send-refuse.out" err="$TEST_DIR/send-refuse.err"
  shift 2
  reset_send_log
  if PATH="$SEND_BIN:$PATH" FAKE_TMUX_LOG="$SEND_LOG" \
    env "$@" "$ROOT/peon-code.sh" send %2 'hello world' >"$out" 2>"$err"; then
    fail "send pasted into $what"
  fi
  assert_contains "$err" "$want"
  assert_not_contains "$SEND_LOG" "paste-buffer"
  assert_not_contains "$SEND_LOG" "send-keys"
}

# Every state that must stop a send before anything is pasted.
test_send_refuses() {
  local empty_box busy_box menu_box bare_box
  empty_box='output line
❯
────'
  busy_box='output line
❯ busy text
────'
  # A menu draws the marker on its selected row with the cursor right after
  # it, so the box measures empty and only the menu itself gives it away.
  menu_box='Do you trust this folder?
❯ 1. Yes, I trust this folder
  2. No, exit'
  bare_box='some other CLI
> ready
────'

  assert_send_refused "a box that already had typed text" "target box busy, retry later" \
    FAKE_BOX="$busy_box" FAKE_CURSOR='11 1'
  # The user typed, then moved the cursor back to the start of the line: the
  # text sits after the cursor, and the box is busy all the same.
  assert_send_refused "a box holding text the cursor had moved back over" "target box busy, retry later" \
    FAKE_BOX="$busy_box" FAKE_CURSOR='2 1'
  # In copy mode a paste lands but Enter goes to the copy-mode key table.
  assert_send_refused "a pane in copy mode" "is in copy mode, retry later" \
    FAKE_BOX="$empty_box" FAKE_CURSOR='2 1' FAKE_IN_MODE=1
  assert_send_refused "a pane sitting on a menu" "is on a dialog or a menu, retry later" \
    FAKE_BOX="$menu_box" FAKE_CURSOR='1 1'
  # No marker means no box peon-code can measure, which no waiting fixes, so
  # the message says to send it by hand instead of to retry.
  assert_send_refused "a pane drawing no prompt marker" "draws no prompt marker peon-code knows" \
    FAKE_BOX="$bare_box" FAKE_CURSOR='7 1'
  assert_send_refused "a pane back at a shell" "back at a shell" \
    FAKE_BOX="$empty_box" FAKE_CURSOR='2 1' FAKE_CMD=zsh
  # Without the launch-time pane option, send would reach any pane on the
  # tmux server, agent pane or not.
  assert_send_refused "a pane peon-code did not launch" "is not a peon-code agent pane" \
    FAKE_BOX="$empty_box" FAKE_CURSOR='2 1' FAKE_PEON_NAME=
}

# What send does once it has pasted: it polls the box and presses Enter only
# for a box holding exactly the message.
test_send_delivers() {
  local empty_box sent_box extra_box payload keys
  empty_box='output line
❯
────'
  sent_box='output line
❯ hello world
────'
  extra_box='output line
❯ hello worldXY
────'

  # The box holds the pasted message only from the fourth poll on, so a send
  # that stopped polling early would never see it.
  reset_send_log
  PATH="$SEND_BIN:$PATH" FAKE_TMUX_LOG="$SEND_LOG" FAKE_SETTLE=3 \
    FAKE_BOX="$empty_box" FAKE_CURSOR='2 1' \
    FAKE_BOX_AFTER="$sent_box" FAKE_CURSOR_AFTER='13 1' \
    "$ROOT/peon-code.sh" send %2 'hello world' >"$TEST_DIR/send-ok.out"
  assert_contains "$TEST_DIR/send-ok.out" "sent to %2"
  assert_contains "$SEND_LOG" "buffer-content:hello world"
  grep -Eq 'paste-buffer -b peon-code-[0-9]+-2 -dpt %2' "$SEND_LOG" ||
    fail "send did not paste through a unique tmux buffer"
  assert_contains "$SEND_LOG" "send-keys -t %2 Enter"
  [ "$(send_captures)" = 5 ] || fail "send made $(send_captures) box reads, expected 5"

  # A box holding more than the message never matches, so send polls to its
  # cap, leaves the box alone, and says so.
  reset_send_log
  if PATH="$SEND_BIN:$PATH" FAKE_TMUX_LOG="$SEND_LOG" \
    FAKE_BOX="$empty_box" FAKE_CURSOR='2 1' \
    FAKE_BOX_AFTER="$extra_box" FAKE_CURSOR_AFTER='15 1' \
    "$ROOT/peon-code.sh" send %2 'hello world' >"$TEST_DIR/send-extra.out" 2>"$TEST_DIR/send-extra.err"; then
    fail "send submitted a box holding more than the message"
  fi
  assert_contains "$TEST_DIR/send-extra.err" "no Enter sent"
  assert_contains "$SEND_LOG" "paste-buffer"
  assert_not_contains "$SEND_LOG" "send-keys"
  [ "$(send_captures)" = 11 ] || fail "send made $(send_captures) box reads, expected 11"

  # A pane that enters copy mode after the paste keeps the message: Enter
  # would go to the copy-mode key table instead of the agent.
  reset_send_log
  if PATH="$SEND_BIN:$PATH" FAKE_TMUX_LOG="$SEND_LOG" FAKE_IN_MODE_AFTER=1 \
    FAKE_BOX="$empty_box" FAKE_CURSOR='2 1' \
    FAKE_BOX_AFTER="$sent_box" FAKE_CURSOR_AFTER='13 1' \
    "$ROOT/peon-code.sh" send %2 'hello world' >"$TEST_DIR/send-mode.out" 2>"$TEST_DIR/send-mode.err"; then
    fail "send pressed Enter on a pane in copy mode"
  fi
  assert_contains "$TEST_DIR/send-mode.err" "went into copy mode"
  assert_contains "$SEND_LOG" "paste-buffer"
  assert_not_contains "$SEND_LOG" "send-keys"

  # A bracketed-paste terminator in the message would end the paste early and
  # hand the rest to the receiving agent as keystrokes; it never gets pasted.
  reset_send_log
  payload=$(printf 'hello \033[201~\rrm -rf /tmp/peon-x')
  PATH="$SEND_BIN:$PATH" FAKE_TMUX_LOG="$SEND_LOG" \
    FAKE_BOX="$empty_box" FAKE_CURSOR='2 1' \
    FAKE_BOX_AFTER='output line
❯ hello [201~rm -rf /tmp/peon-x
────' FAKE_CURSOR_AFTER='31 1' \
    "$ROOT/peon-code.sh" send %2 "$payload" >"$TEST_DIR/send-esc.out"
  assert_contains "$TEST_DIR/send-esc.out" "sent to %2"
  assert_contains "$SEND_LOG" "buffer-content:hello [201~rm -rf /tmp/peon-x"
  if grep -Fq "$(printf '\033')" "$SEND_LOG"; then
    fail "send pasted an escape character into the pane"
  fi
  keys=$(grep -c '^send-keys' "$SEND_LOG" || true)
  [ "$keys" = 1 ] || fail "send made $keys send-keys calls, expected only the Enter"

  # A message of - comes in on stdin, so quoting it is the shell's problem,
  # not the sending agent's.
  reset_send_log
  PATH="$SEND_BIN:$PATH" FAKE_TMUX_LOG="$SEND_LOG" \
    FAKE_BOX="$empty_box" FAKE_CURSOR='2 1' \
    FAKE_BOX_AFTER="output line
❯ it is the user's box
────" FAKE_CURSOR_AFTER='21 1' \
    "$ROOT/peon-code.sh" send %2 - >"$TEST_DIR/send-stdin.out" <<'PEON'
it is the user's box
PEON
  assert_contains "$TEST_DIR/send-stdin.out" "sent to %2"
  assert_contains "$SEND_LOG" "buffer-content:it is the user's box"
  assert_contains "$SEND_LOG" "send-keys -t %2 Enter"
}

# Every agent must reopen its own thread: same-CLI panes share a directory,
# so a per-agent marker is what keeps them off each other's conversation.
test_resume_picks_each_agent_thread() {
  local fake_bin=$1 log="$TEST_DIR/tmux-resume.log" home_dir="$TEST_DIR/home-resume"
  local work_dir="$TEST_DIR/resume-work" claude_dir codex_dir slug launch
  local copilot_dir gemini_dir qwen_dir hash
  mkdir -p "$home_dir" "$work_dir"
  work_dir=$(cd "$work_dir" && pwd)  # the launcher sees the normalized path
  slug=${work_dir//[^A-Za-z0-9]/-}
  claude_dir="$home_dir/.claude/projects/$slug"
  codex_dir="$home_dir/.codex/sessions/2026/07/26"
  copilot_dir="$home_dir/.copilot/session-state/44444444-4444-4444-4444-444444444444"
  hash=$(printf '%s' "$work_dir" | shasum -a 256 2>/dev/null) ||
    hash=$(printf '%s' "$work_dir" | sha256sum)
  gemini_dir="$home_dir/.gemini/tmp/${hash%% *}/chats"
  qwen_dir="$home_dir/.qwen/projects/$slug/chats"
  mkdir -p "$claude_dir" "$codex_dir" "$copilot_dir" "$gemini_dir" "$qwen_dir"
  printf 'agent boss of peon-code session resume-test, in pane\n' \
    >"$claude_dir/11111111-1111-1111-1111-111111111111.jsonl"
  printf 'agent second of peon-code session resume-test, in pane\n' \
    >"$claude_dir/22222222-2222-2222-2222-222222222222.jsonl"
  printf '{"cwd":"%s"}\nagent impl of peon-code session resume-test, in pane\n' "$work_dir" \
    >"$codex_dir/rollout-2026-07-26T00-00-00-33333333-3333-3333-3333-333333333333.jsonl"
  printf '{"type":"session.start","data":{"context":{"cwd":"%s"}}}\nagent cop of peon-code session resume-test, in pane\n' "$work_dir" \
    >"$copilot_dir/events.jsonl"
  # One line holding a nested sessionId after the real one: the top-level id must win.
  printf '{"sessionId":"55555555-5555-5555-5555-555555555555","messages":[{"text":"agent gem of peon-code session resume-test, in pane"}],"extra":{"sessionId":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}}\n' \
    >"$gemini_dir/session-20260726-000000-55555555.jsonl"
  printf 'agent qw of peon-code session resume-test, in pane\n' \
    >"$qwen_dir/66666666-6666-6666-6666-666666666666.jsonl"
  # A qwen id can be a saved-chat tag shorter than a uuid.
  printf 'agent qw2 of peon-code session resume-test, in pane\n' \
    >"$qwen_dir/mytag.jsonl"
  sleep 1  # the decoy transcripts sort newer than the real ones
  printf 'agent boss of peon-code session resume-test2, in pane\n' \
    >"$claude_dir/99999999-9999-9999-9999-999999999999.jsonl"
  # Same marker, other directory: the copilot store is shared across directories.
  mkdir -p "$home_dir/.copilot/session-state/88888888-8888-8888-8888-888888888888"
  printf '{"type":"session.start","data":{"context":{"cwd":"%s"}}}\nagent cop of peon-code session resume-test, in pane\n' "$work_dir/elsewhere" \
    >"$home_dir/.copilot/session-state/88888888-8888-8888-8888-888888888888/events.jsonl"
  printf 'boss claude -\n*second claude -\nimpl codex manager\nscout codex -\ncop copilot -\ngem gemini -\nqw qwen -\nqw2 qwen -\n' \
    >"$work_dir/peon-code.conf"

  (
    cd "$work_dir"
    PATH="$fake_bin:$PATH" HOME="$home_dir" TMPDIR="$TEST_DIR" \
      FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=launch FAKE_TMUX_PANES=8 \
      "$ROOT/peon-code.sh" resume resume-test
  ) >"$TEST_DIR/resume.out" 2>"$TEST_DIR/resume.err" || true

  launch=$(grep -F 'buffer-content:claude' "$log")
  assert_contains <(printf '%s\n' "$launch") \
    "buffer-content:claude --resume 11111111-1111-1111-1111-111111111111"
  assert_contains <(printf '%s\n' "$launch") \
    "buffer-content:claude --resume 22222222-2222-2222-2222-222222222222"
  assert_contains "$log" "buffer-content:codex resume 33333333-3333-3333-3333-333333333333"
  assert_contains "$log" "buffer-content:copilot --resume=44444444-4444-4444-4444-444444444444 -i"
  assert_contains "$log" "buffer-content:gemini --resume 55555555-5555-5555-5555-555555555555 -i"
  assert_contains "$log" "buffer-content:qwen --resume 66666666-6666-6666-6666-666666666666 -i"
  assert_contains "$log" "buffer-content:qwen --resume mytag -i"
  assert_contains "$TEST_DIR/resume.err" "no earlier thread for scout"
  # A session name that is a prefix of another must not match its transcripts.
  assert_not_contains "$log" "99999999-9999-9999-9999-999999999999"
  # The copilot match from the other directory must not be resumed.
  assert_not_contains "$log" "88888888-8888-8888-8888-888888888888"
  # The nested sessionId in the gemini body must not be resumed.
  assert_not_contains "$log" "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
  # The *-marked agent (not the manager) is moved into the main slot of a
  # main-vertical layout, and the mark is stripped from its name.
  assert_contains "$log" "swap-pane -d -s %2 -t %1"
  assert_contains "$log" "select-layout -t resume-test:agents main-vertical"

  # Without a * mark, the first manager-role agent takes the main slot.
  : >"$log"
  printf 'boss claude -\nimpl codex manager\n' >"$work_dir/peon-code.conf"
  (
    cd "$work_dir"
    PATH="$fake_bin:$PATH" HOME="$home_dir" TMPDIR="$TEST_DIR" \
      FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=launch FAKE_TMUX_PANES=2 \
      "$ROOT/peon-code.sh" mgr-fallback
  ) >"$TEST_DIR/mgr.out" 2>"$TEST_DIR/mgr.err" || true
  assert_contains "$log" "swap-pane -d -s %2 -t %1"

  printf '*a claude -\n*b claude -\n' >"$work_dir/peon-code.conf"
  (
    cd "$work_dir"
    PATH="$fake_bin:$PATH" HOME="$home_dir" TMPDIR="$TEST_DIR" \
      FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=launch \
      "$ROOT/peon-code.sh" two-mains
  ) >"$TEST_DIR/two-mains.out" 2>"$TEST_DIR/two-mains.err" &&
    fail "a config with two main marks was accepted"
  assert_contains "$TEST_DIR/two-mains.err" "a second agent is marked main with *"
}

# The resume-summary picker is answered with Enter (its summary default);
# a pane already at the input line is left alone.
test_resume_picker_answered() {
  local fake_bin=$1 log="$TEST_DIR/picker.log" bin_dir="$TEST_DIR/picker-bin"
  mkdir -p "$bin_dir"
  cp "$fake_bin/sleep" "$bin_dir/sleep"
  cat >"$bin_dir/tmux" <<'FAKE_TMUX'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_TMUX_LOG"
case ${1:-} in
  capture-pane) printf '%s\n' "$FAKE_TMUX_CAPTURE" ;;
esac
FAKE_TMUX
  chmod +x "$bin_dir/tmux"

  : >"$log"
  FAKE_TMUX_LOG="$log" PATH="$bin_dir:$PATH" \
    FAKE_TMUX_CAPTURE='❯ 1. Resume from summary (recommended)' \
    bash -c 'source "$1/lib/tmux.sh"; answer_resume_picker %9' _ "$ROOT"
  assert_contains "$log" "send-keys -t %9 Enter"

  : >"$log"
  FAKE_TMUX_LOG="$log" PATH="$bin_dir:$PATH" \
    FAKE_TMUX_CAPTURE='❯ try "fix the tests"' \
    bash -c 'source "$1/lib/tmux.sh"; answer_resume_picker %9' _ "$ROOT"
  assert_not_contains "$log" "send-keys"
}

# One box measured from a synthetic capture: the capture's second row holds
# the box, the cursor sits on it, and the wanted text is what pane_box_text
# returns for it.
assert_box() {
  local what=$1 want=$2 cap=$3 got
  got=$(FAKE_TMUX_CAPTURE="$cap" PATH="$BOX_BIN:$PATH" \
    bash -c 'source "$1/lib/tmux.sh"; pane_box_text %9' _ "$ROOT") ||
    fail "pane_box_text failed on $what"
  [ "$got" = "$want" ] || fail "box for $what is '$got', expected '$want'"
}

# Text a TUI draws dim or in a gray foreground is a hint, not typed text, so
# a box holding only hints measures empty.
test_box_hint_text() {
  local bin_dir="$TEST_DIR/box-bin" e tail
  mkdir -p "$bin_dir"
  cat >"$bin_dir/tmux" <<'FAKE_TMUX'
#!/usr/bin/env bash
case ${1:-} in
  display) printf '1\n' ;;
  capture-pane) printf '%s\n' "$FAKE_TMUX_CAPTURE" ;;
esac
FAKE_TMUX
  chmod +x "$bin_dir/tmux"
  BOX_BIN=$bin_dir
  e=$(printf '\033')
  tail='
────'

  assert_box "a dim hint" "" "output line
❯ ${e}[2mTry \"fix the bug\"${e}[0m$tail"
  assert_box "a 256-color gray hint" "" "output line
❯ ${e}[38;5;242mTry \"fix the bug\"${e}[0m$tail"
  assert_box "a bright-black hint" "" "output line
❯ ${e}[90mTry \"fix the bug\"${e}[39m$tail"
  assert_box "dim combined with a gray foreground, reset bare" "" "output line
❯ ${e}[2;38;5;245mTry \"fix the bug\"${e}[m$tail"
  # The marker itself carries the hint style, and is still found.
  assert_box "a hint drawn over the marker" "" "output line
${e}[2m❯ Try \"fix the bug\"${e}[0m$tail"
  assert_box "styled but not hinted text" "hello world" "output line
❯ ${e}[1;38;5;39mhello world${e}[0m$tail"
  # The gray range ends at 249: 250 and above are near-white, which a theme
  # can use for ordinary text.
  assert_box "the last gray index" "" "output line
❯ ${e}[38;5;249mTry \"fix the bug\"${e}[0m$tail"
  assert_box "a near-white foreground" "hello world" "output line
❯ ${e}[38;5;250mhello world${e}[0m$tail"
  # A truecolor foreground is gray when its channels are near-equal, and
  # near-white or colored otherwise.
  assert_box "a truecolor gray hint" "" "output line
❯ ${e}[38;2;136;136;136mTry \"fix the bug\"${e}[0m$tail"
  assert_box "a truecolor near-white foreground" "hello world" "output line
❯ ${e}[38;2;250;250;250mhello world${e}[0m$tail"
  assert_box "a truecolor colored foreground" "hello world" "output line
❯ ${e}[38;2;200;120;40mhello world${e}[0m$tail"
  # Italic alone is not a hint style: CLIs draw ordinary text in it too.
  assert_box "an italic hint" "Try \"fix the bug\"" "output line
❯ ${e}[3mTry \"fix the bug\"${e}[0m$tail"
  assert_box "a white foreground" "hello world" "output line
❯ ${e}[38;5;255mhello world${e}[0m$tail"
  assert_box "typed text with a hint after it" "hello world" "output line
❯ hello world ${e}[2m(esc to clear)${e}[0m$tail"
  assert_box "plain typed text" "hello world" "output line
❯ hello world$tail"
  # A background or underline color carries sub-parameters of its own, which
  # are not attributes: reading them as attributes blanks real typed text.
  assert_box "a 256-color background" "hello world" "output line
❯ ${e}[48;5;90mhello world${e}[0m$tail"
  assert_box "a background whose index reads as dim" "hello world" "output line
❯ ${e}[48;5;2mhello world${e}[0m$tail"
  assert_box "a truecolor background" "hello world" "output line
❯ ${e}[48;2;38;5;242mhello world${e}[0m$tail"
  assert_box "an underline color" "hello world" "output line
❯ ${e}[58;5;2mhello world${e}[0m$tail"
  # An OSC 8 hyperlink: the URL is not text the box holds.
  assert_box "a hyperlink" "see docs" "output line
❯ ${e}]8;;https://ex.com${e}\\see${e}]8;;${e}\\ docs$tail"
  assert_box "a hyperlink ended with BEL" "see docs" "output line
❯ ${e}]8;;https://ex.com$(printf '\007')see${e}]8;;$(printf '\007') docs$tail"
}

# rebrief re-pastes the brief file stored in @peon_brief; a pane with no
# stored brief is skipped with a note, and sending none is an error.
test_rebrief() {
  local fake_bin=$1 log="$TEST_DIR/tmux-rebrief.log" home_dir="$TEST_DIR/home-rebrief"
  local empty_box='output line
❯
────'
  mkdir -p "$home_dir"
  printf 'You are boss, follow the rules.\n' >"$TEST_DIR/rebrief-brief.md"

  PATH="$fake_bin:$PATH" HOME="$home_dir" FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=owned \
    FAKE_TMUX_BRIEF="$TEST_DIR/rebrief-brief.md" FAKE_TMUX_CAPTURE="$empty_box" \
    "$ROOT/peon-code.sh" rebrief all owned >"$TEST_DIR/rebrief.out"
  assert_contains "$TEST_DIR/rebrief.out" "rebriefed 1 pane(s) in session owned"
  assert_contains "$log" "buffer-content:You are boss, follow the rules."

  : >"$log"
  if PATH="$fake_bin:$PATH" HOME="$home_dir" FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=owned \
    "$ROOT/peon-code.sh" rebrief all owned >"$TEST_DIR/rebrief-none.out" 2>"$TEST_DIR/rebrief-none.err"; then
    fail "rebrief succeeded with no stored brief"
  fi
  assert_contains "$TEST_DIR/rebrief-none.err" "no stored brief for impl"

  : >"$log"
  if PATH="$fake_bin:$PATH" HOME="$home_dir" FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=owned \
    FAKE_TMUX_BRIEF="$TEST_DIR/rebrief-brief.md" FAKE_TMUX_CAPTURE="$empty_box" \
    FAKE_LOAD_BUFFER_EXIT=3 \
    "$ROOT/peon-code.sh" rebrief all owned >"$TEST_DIR/rebrief-fail.out" 2>"$TEST_DIR/rebrief-fail.err"; then
    fail "rebrief succeeded with a refused paste"
  fi
  assert_contains "$TEST_DIR/rebrief-fail.err" "no brief sent to impl %1: tmux refused the paste"
  assert_not_contains "$TEST_DIR/rebrief-fail.out" "rebriefed 1 pane(s)"
  assert_not_contains "$log" "paste-buffer"
  assert_not_contains "$log" "send-keys"

  : >"$log"
  if PATH="$fake_bin:$PATH" HOME="$home_dir" FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=owned \
    FAKE_TMUX_BRIEF="$TEST_DIR/rebrief-brief.md" FAKE_TMUX_CAPTURE='some other CLI
> ready' \
    "$ROOT/peon-code.sh" rebrief all owned >"$TEST_DIR/rebrief-bare.out" 2>"$TEST_DIR/rebrief-bare.err"; then
    fail "rebrief succeeded on a pane drawing no prompt marker"
  fi
  assert_contains "$TEST_DIR/rebrief-bare.err" "no brief sent to impl %1: it draws no prompt marker peon-code knows"
  assert_not_contains "$log" "load-buffer"
  assert_not_contains "$log" "paste-buffer"
}

# compact pastes the /compact slash command with nothing around it, and only
# into a pane whose input box is empty.
test_compact() {
  local fake_bin=$1 log="$TEST_DIR/tmux-compact.log" bin_dir="$TEST_DIR/compact-bin"
  local empty_box busy_box typed_box menu_box brief="$TEST_DIR/compact-brief.md"
  local enter_line brief_line settle_reads
  mkdir -p "$bin_dir"
  cp "$fake_bin/sleep" "$bin_dir/sleep"
  cat >"$bin_dir/tmux" <<'FAKE_TMUX'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_TMUX_LOG"
pane=%1
case "$*" in *%2*) pane=%2 ;; esac
box=$FAKE_BOX
[ "$pane" = %2 ] && box=$FAKE_BOX2
# A pane shows the pasted command in its box once the paste has reached it,
# and empties the box again once the Enter submits it.
grep -Fq -- "-dpt $pane" "$FAKE_TMUX_LOG" && box=$FAKE_BOX_AFTER
grep -Fqx -- "send-keys -t $pane Enter" "$FAKE_TMUX_LOG" && box=$FAKE_BOX
case ${1:-} in
  has-session) ;;
  show-options)
    case "$*" in
      *@peon_brief*) printf '%s\n' "${FAKE_TMUX_BRIEF:-}" ;;
      *) printf '1\n' ;;
    esac
    ;;
  list-panes) printf '%s\n' "${FAKE_PANES:-%1 node impl}" ;;
  display)
    case "$*" in
      *pane_in_mode*) printf '0\n' ;;
      *cursor_y*) printf '1\n' ;;
    esac
    ;;
  capture-pane)
    printf '%s\n' "$box"
    # A pane that keeps redrawing: every capture differs, so it never settles.
    [ -n "${FAKE_UNSETTLED:-}" ] && printf 'redrawing %s\n' "$(wc -l <"$FAKE_TMUX_LOG")"
    ;;
  load-buffer) printf 'buffer-content:%s\n' "$(cat)" >>"$FAKE_TMUX_LOG" ;;
esac
exit 0
FAKE_TMUX
  chmod +x "$bin_dir/tmux"
  empty_box='output line
❯
────'
  busy_box='output line
❯ half a question
────'
  typed_box='output line
❯ /compact
────'
  menu_box='Do you trust this folder?
❯ 1. Yes, I trust this folder
  2. No, exit'
  printf 'You are impl, follow the rules.\n' >"$brief"

  : >"$log"
  PATH="$bin_dir:$PATH" FAKE_TMUX_LOG="$log" FAKE_BOX="$empty_box" \
    FAKE_BOX_AFTER="$typed_box" FAKE_TMUX_BRIEF="$brief" \
    "$ROOT/peon-code.sh" compact all owned >"$TEST_DIR/compact.out"
  # No [from user] prefix and nothing else: a prefix stops the CLI from
  # reading the line as a slash command.
  grep -Fqx -- 'buffer-content:/compact' "$log" ||
    fail "compact pasted something other than /compact alone"
  assert_contains "$log" "send-keys -t %1 Enter"
  assert_contains "$TEST_DIR/compact.out" "sent /compact to 1 pane(s) in session owned"
  # The brief goes back in once the pane has settled, so the agent gets its
  # standing instructions after the compaction dropped them.
  assert_contains "$log" "buffer-content:You are impl, follow the rules."
  enter_line=$(grep -n -Fx -- 'send-keys -t %1 Enter' "$log" | head -1 | cut -d: -f1)
  brief_line=$(grep -n -F -- 'buffer-content:You are impl' "$log" | head -1 | cut -d: -f1)
  [ -n "$enter_line" ] && [ "$brief_line" -gt "$enter_line" ] ||
    fail "compact pasted the brief before submitting /compact"
  settle_reads=$(awk -v a="$enter_line" -v b="$brief_line" \
    'NR > a && NR < b && /^capture-pane/ { n++ } END { print n + 0 }' "$log")
  [ "$settle_reads" -ge 2 ] ||
    fail "compact made $settle_reads box reads between /compact and the brief, expected a settle wait"

  : >"$log"
  if PATH="$bin_dir:$PATH" FAKE_TMUX_LOG="$log" FAKE_BOX="$busy_box" \
    "$ROOT/peon-code.sh" compact >"$TEST_DIR/compact-busy.out" 2>"$TEST_DIR/compact-busy.err"; then
    fail "compact pasted into a box holding typed text"
  fi
  assert_contains "$TEST_DIR/compact-busy.err" "its input box holds typed text"
  assert_not_contains "$log" "paste-buffer"
  assert_not_contains "$log" "send-keys"

  : >"$log"
  if PATH="$bin_dir:$PATH" FAKE_TMUX_LOG="$log" FAKE_BOX="$empty_box" \
    "$ROOT/peon-code.sh" compact nobody owned >"$TEST_DIR/compact-name.out" 2>"$TEST_DIR/compact-name.err"; then
    fail "compact accepted an unknown pane name"
  fi
  assert_contains "$TEST_DIR/compact-name.err" "no pane named nobody in session owned"
  assert_contains "$TEST_DIR/compact-name.err" "impl %1"
  assert_not_contains "$log" "paste-buffer"

  # Two panes, one free and one holding typed text: the free one is compacted
  # and the busy one is left as the user typed it.
  : >"$log"
  PATH="$bin_dir:$PATH" FAKE_TMUX_LOG="$log" FAKE_BOX="$empty_box" \
    FAKE_BOX_AFTER="$typed_box" FAKE_BOX2="$busy_box" FAKE_TMUX_BRIEF="$brief" \
    FAKE_PANES='%1 node impl
%2 node boss' \
    "$ROOT/peon-code.sh" compact all owned \
    >"$TEST_DIR/compact-partial.out" 2>"$TEST_DIR/compact-partial.err"
  assert_contains "$TEST_DIR/compact-partial.out" "sent /compact to 1 pane(s) in session owned"
  [ "$(grep -c -Fx -- 'buffer-content:/compact' "$log")" = 1 ] ||
    fail "compact pasted /compact more than once"
  assert_contains "$log" "send-keys -t %1 Enter"
  assert_not_contains "$log" "send-keys -t %2"
  assert_not_contains "$log" "-dpt %2"
  assert_contains "$TEST_DIR/compact-partial.err" "skipped %2: its input box holds typed text"
  # Only the compacted pane is rebriefed; the busy one is left as the user
  # typed it.
  [ "$(grep -c -F -- 'buffer-content:You are impl' "$log")" = 1 ] ||
    fail "compact pasted the brief into a pane it skipped"

  # A pane that keeps redrawing after /compact never settles, so its brief is
  # held back rather than pasted over whatever is on screen.
  : >"$log"
  PATH="$bin_dir:$PATH" FAKE_TMUX_LOG="$log" FAKE_BOX="$empty_box" \
    FAKE_BOX_AFTER="$typed_box" FAKE_TMUX_BRIEF="$brief" FAKE_UNSETTLED=1 \
    "$ROOT/peon-code.sh" compact all owned \
    >"$TEST_DIR/compact-busy-after.out" 2>"$TEST_DIR/compact-busy-after.err"
  assert_contains "$TEST_DIR/compact-busy-after.out" "sent /compact to 1 pane(s) in session owned"
  assert_contains "$TEST_DIR/compact-busy-after.err" "no brief sent to impl %1: it is still busy after compacting"
  assert_not_contains "$log" "buffer-content:You are impl"

  # A brief is held back from a box holding typed text, so text typed while a
  # pane compacted is left as the user typed it.
  : >"$log"
  if PATH="$bin_dir:$PATH" FAKE_TMUX_LOG="$log" FAKE_BOX="$busy_box" \
    FAKE_TMUX_BRIEF="$brief" \
    "$ROOT/peon-code.sh" rebrief all owned \
    >"$TEST_DIR/rebrief-typed.out" 2>"$TEST_DIR/rebrief-typed.err"; then
    fail "rebrief pasted into a box holding typed text"
  fi
  assert_contains "$TEST_DIR/rebrief-typed.err" "no brief sent to impl %1: its input box holds typed text"
  assert_not_contains "$log" "load-buffer"
  assert_not_contains "$log" "paste-buffer"
  assert_not_contains "$log" "send-keys"

  # A pane sitting on a menu measures an empty box, so only the menu itself
  # keeps the brief out; the Enter after a paste would answer the menu.
  : >"$log"
  if PATH="$bin_dir:$PATH" FAKE_TMUX_LOG="$log" FAKE_BOX="$menu_box" \
    FAKE_TMUX_BRIEF="$brief" \
    "$ROOT/peon-code.sh" rebrief all owned \
    >"$TEST_DIR/rebrief-menu.out" 2>"$TEST_DIR/rebrief-menu.err"; then
    fail "rebrief pasted into a pane on a menu"
  fi
  assert_contains "$TEST_DIR/rebrief-menu.err" \
    "no brief sent to impl %1: its input box holds typed text, or it is on a dialog or a menu"
  assert_not_contains "$log" "load-buffer"
  assert_not_contains "$log" "paste-buffer"
  assert_not_contains "$log" "send-keys"
}

bash -n "$ROOT/peon-code.sh" "$ROOT/lib/config.sh" "$ROOT/lib/tmux.sh" \
  "$ROOT/install.sh"
fake_bin=$(make_fake_commands)
test_install_guard
test_session_ownership "$fake_bin"
test_unique_buffers_and_launch_failure "$fake_bin"
test_config_loading "$fake_bin"
SEND_BIN=$(make_send_bin "$fake_bin")
test_send_refuses
test_send_delivers
test_resume_picks_each_agent_thread "$fake_bin"
test_resume_picker_answered "$fake_bin"
test_box_hint_text
test_rebrief "$fake_bin"
test_compact "$fake_bin"
echo "tests: PASS"
