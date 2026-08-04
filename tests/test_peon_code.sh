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
    printf 'zsh\n'
    ;;
  capture-pane)
    ;;
  load-buffer)
    content=$(cat)
    printf 'buffer-content:%s\n' "$content" >>"$FAKE_TMUX_LOG"
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

# rebrief re-pastes the brief file stored in @peon_brief; a pane with no
# stored brief is skipped with a note, and sending none is an error.
test_rebrief() {
  local fake_bin=$1 log="$TEST_DIR/tmux-rebrief.log" home_dir="$TEST_DIR/home-rebrief"
  mkdir -p "$home_dir"
  printf 'You are boss, follow the rules.\n' >"$TEST_DIR/rebrief-brief.md"

  PATH="$fake_bin:$PATH" HOME="$home_dir" FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=owned \
    FAKE_TMUX_BRIEF="$TEST_DIR/rebrief-brief.md" \
    "$ROOT/peon-code.sh" rebrief all owned >"$TEST_DIR/rebrief.out"
  assert_contains "$TEST_DIR/rebrief.out" "rebriefed 1 pane(s) in session owned"
  assert_contains "$log" "buffer-content:You are boss, follow the rules."

  : >"$log"
  if PATH="$fake_bin:$PATH" HOME="$home_dir" FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=owned \
    "$ROOT/peon-code.sh" rebrief all owned >"$TEST_DIR/rebrief-none.out" 2>"$TEST_DIR/rebrief-none.err"; then
    fail "rebrief succeeded with no stored brief"
  fi
  assert_contains "$TEST_DIR/rebrief-none.err" "no stored brief for impl"
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
test_rebrief "$fake_bin"
echo "tests: PASS"
