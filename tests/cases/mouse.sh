#!/usr/bin/env bash
set -euo pipefail
CASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/helpers.sh
. "$CASE_DIR/../helpers.sh"

test_explain() {
  local bin_dir log="$TEST_DIR/explain.log" text
  bin_dir=$(make_send_bin "$(make_fake_commands)")
  text=$(cat <<'TEXT'
It's "quoted" text, with `backticks` and $(shell syntax).
A second line: 日本語.
TEXT
)
  PATH="$bin_dir:$PATH" FAKE_TMUX_LOG="$log" \
    FAKE_BOX=$'output\n❯\n────' FAKE_CURSOR='2 1' \
    FAKE_BOX_AFTER=$'output\n❯ [Pasted Content 180 chars]\n────' FAKE_CURSOR_AFTER='36 1' \
    "$ROOT/peon-code.sh" explain %2 <<<"$text"
  assert_contains "$log" 'buffer-content:Explain what the following text means in this conversation:'
  [[ $(cat "$log") == *"$text"* ]] || fail "explain changed the selected text"
  assert_contains "$log" 'send-keys -t %2 Enter'
  assert_contains "$log" 'display-message -t %2 -- peon-code: sent to %2'
  assert_not_contains "$log" 'send-keys -t %1'

  : >"$log"
  if PATH="$bin_dir:$PATH" FAKE_TMUX_LOG="$log" \
    FAKE_BOX=$'output\n❯ half a thought\n────' FAKE_CURSOR='16 1' \
    FAKE_BOX_AFTER='' FAKE_CURSOR_AFTER='2 1' \
    "$ROOT/peon-code.sh" explain %2 <<<"$text"; then
    fail "explain submitted over typed input"
  fi
  assert_not_contains "$log" 'paste-buffer'
  assert_not_contains "$log" 'send-keys'
  assert_contains "$log" 'target box busy after 10 tries'

  : >"$log"
  if PATH="$bin_dir:$PATH" FAKE_TMUX_LOG="$log" \
    "$ROOT/peon-code.sh" explain %2 <<< $' \t\n'; then
    fail "explain accepted an empty selection"
  fi
  assert_contains "$log" 'no selected text'
  assert_not_contains "$log" 'paste-buffer'
}

test_explain
echo 'explain: PASS'
