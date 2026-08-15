#!/usr/bin/env bash
set -euo pipefail
CASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tests/helpers.sh
. "$CASE_DIR/../helpers.sh"

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

test_box_hint_text
echo "box: PASS"
