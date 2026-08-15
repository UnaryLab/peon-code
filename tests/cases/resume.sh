#!/usr/bin/env bash
set -euo pipefail
CASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/helpers.sh
. "$CASE_DIR/../helpers.sh"

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
  # grok keys its store by url-encoding the path; reuse the real encoder so the
  # test tracks it. The id is the session directory holding the transcript.
  local grok_enc grok_dir
  grok_enc=$(bash -c 'source "$1/lib/config.sh"; url_encode "$2"' _ "$ROOT" "$work_dir")
  grok_dir="$home_dir/.grok/sessions/$grok_enc/77777777-7777-7777-7777-777777777777"
  mkdir -p "$claude_dir" "$codex_dir" "$copilot_dir" "$gemini_dir" "$qwen_dir" "$grok_dir"
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
  # grok records the prompt in chat_history.jsonl; events.jsonl holds no marker.
  printf '{"ts":"2026-07-26T00:00:00Z","type":"mcp"}\n' >"$grok_dir/events.jsonl"
  printf '{"type":"user","content":"agent gk of peon-code session resume-test, in pane"}\n' \
    >"$grok_dir/chat_history.jsonl"
  sleep 1  # the decoy transcripts sort newer than the real ones
  printf 'agent boss of peon-code session resume-test2, in pane\n' \
    >"$claude_dir/99999999-9999-9999-9999-999999999999.jsonl"
  # Same marker, other directory: the copilot store is shared across directories.
  mkdir -p "$home_dir/.copilot/session-state/88888888-8888-8888-8888-888888888888"
  printf '{"type":"session.start","data":{"context":{"cwd":"%s"}}}\nagent cop of peon-code session resume-test, in pane\n' "$work_dir/elsewhere" \
    >"$home_dir/.copilot/session-state/88888888-8888-8888-8888-888888888888/events.jsonl"
  # Same marker under a different encoded cwd: grok's per-directory store keeps
  # it out of this directory's resume.
  local grok_decoy
  grok_decoy="$home_dir/.grok/sessions/$(bash -c 'source "$1/lib/config.sh"; url_encode "$2"' _ "$ROOT" "$work_dir/elsewhere")/dddddddd-dddd-dddd-dddd-dddddddddddd"
  mkdir -p "$grok_decoy"
  printf '{"type":"user","content":"agent gk of peon-code session resume-test, in pane"}\n' \
    >"$grok_decoy/chat_history.jsonl"
  printf 'boss claude -\n*second claude -\nimpl codex manager\nscout codex -\ncop copilot -\ngem gemini -\nqw qwen -\nqw2 qwen -\ngk grok -\n' \
    >"$work_dir/peon-code.conf"

  (
    cd "$work_dir"
    PATH="$fake_bin:$PATH" HOME="$home_dir" TMPDIR="$TEST_DIR" \
      FAKE_TMUX_LOG="$log" FAKE_TMUX_MODE=launch FAKE_TMUX_PANES=9 \
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
  assert_contains "$log" "buffer-content:grok --resume 77777777-7777-7777-7777-777777777777"
  assert_contains "$TEST_DIR/resume.err" "no earlier thread for scout"
  # A session name that is a prefix of another must not match its transcripts.
  assert_not_contains "$log" "99999999-9999-9999-9999-999999999999"
  # The copilot match from the other directory must not be resumed.
  assert_not_contains "$log" "88888888-8888-8888-8888-888888888888"
  # The grok match from the other encoded directory must not be resumed.
  assert_not_contains "$log" "dddddddd-dddd-dddd-dddd-dddddddddddd"
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

fake_bin=$(make_fake_commands)
test_resume_picks_each_agent_thread "$fake_bin"
test_resume_picker_answered "$fake_bin"
echo "resume: PASS"
