# shellcheck shell=bash

# shellcheck source=lib/cli.sh
declare -F cli_call >/dev/null || source "$(dirname -- "${BASH_SOURCE[0]}")/cli.sh"

# Session name for a directory: the given name, else the current directory.
# tmux rewrites . and : in session names, so match what it stores.
session_name() {
  local s=${1:-${PWD##*/}}
  s=${s:-peon-code}  # PWD is /
  printf '%s\n' "${s//[.:]/_}"
}

# The @peon_name pane option carries the agent name: unlike the pane title,
# an app cannot overwrite it. Panes without it are not ours and are skipped,
# as are panes running a shell: pasted text there would run as commands.
# With a session argument, only that session's panes; teams share agent
# names, so an unscoped match would reach every team on the server.
list_agent_panes() {
  local id cmd name scope=(-a)
  [ $# -gt 0 ] && scope=(-s -t "=$1")
  tmux list-panes "${scope[@]}" -F '#{pane_id} #{pane_current_command} #{@peon_name}' 2>/dev/null |
    while read -r id cmd name; do
      [ -n "$name" ] || continue
      case $cmd in
        sh|bash|zsh|fish|dash|ksh) continue ;;
      esac
      echo "$id $name"
    done
}

# Wait until a pane's shell has started: it reports a shell, or has drawn
# something. Bounded, so a pane that never reports still lets the run finish.
wait_shell_ready() {
  local pane=$1 i cur out
  for ((i = 0; i < 50; i++)); do
    cur=$(tmux display -pt "$pane" '#{pane_current_command}' 2>/dev/null) || cur=""
    case $cur in
      sh|bash|zsh|fish|dash|ksh) return 0 ;;
    esac
    out=$(tmux capture-pane -pt "$pane" 2>/dev/null) || out=""
    [ -n "${out//[[:space:]]/}" ] && return 0
    sleep 0.2
  done
}

# Wait until the agent CLI has replaced the shell in a pane.
wait_agent_ready() {
  local pane=$1 i cur
  for ((i = 0; i < 100; i++)); do
    cur=$(tmux display -pt "$pane" '#{pane_current_command}' 2>/dev/null) || cur=""
    case $cur in
      sh|bash|zsh|fish|dash|ksh|"") sleep 0.2 ;;
      *) return 0 ;;
    esac
  done
  return 1
}

# Answer a startup dialog whose default row is the wanted answer, by pressing
# Enter once the pane shows text matching the glob pattern. One dialog is
# answered this way: claude's picker for resuming a large or old session
# ("Resume from summary (recommended)"). A pane that reaches its input line
# first never showed the dialog, so the wait ends there. Always returns 0: a
# pane still drawing after the cap, 15s, is left for wait_pane_settled to
# judge.
# The input-line check uses the provider markers; a CLI drawing
# another marker waits the full cap when it shows no dialog.
answer_dialog() {
  local pane=$1 pattern=$2 i cur cy rc markers
  cli_select_pane "$pane"
  markers=$CLI_PROMPT_MARKERS
  for ((i = 0; i < 50; i++)); do
    cur=$(tmux capture-pane -pt "$pane" 2>/dev/null && printf '.') || cur=""
    cur=${cur%.}
    cy=$(tmux display -pt "$pane" '#{cursor_y}' 2>/dev/null) || cy=""
    # shellcheck disable=SC2053  # unquoted on purpose: the pattern is a glob
    if [[ $cur == $pattern ]]; then
      tmux send-keys -t "$pane" Enter
      return 0
    fi
    # Input line drawn and no menu on screen: the pane never showed a dialog.
    rc=0
    pane_has_menu "$cur" "$cy" || rc=$?
    if [ "$rc" -eq 1 ] && [ -n "$markers" ] && [[ $cur =~ $markers ]]; then
      return 0
    fi
    sleep 0.3
  done
  return 0
}

# Wait until a known prompt line is drawn and the pane has stopped
# changing: a capture holds a line starting with the prompt marker and
# matches the capture 0.3s before. A menu such as the folder-trust dialog
# draws the same marker on its selected row, so a capture holding a menu
# is never settled: the wait continues until the user answers it.
# A CLI without a marker needs three unchanged, nonblank captures instead.
# The tries cap, 30s by default, ends the wait when a spinner keeps redrawing,
# the prompt never shows, or the dialog goes unanswered; the caller then
# skips the paste rather than typing into whatever is on screen.
wait_pane_settled() {
  local pane=$1 tries=${2:-100} i prev="" cur cy rc markers stable=0
  cli_select_pane "$pane"
  markers=$CLI_PROMPT_MARKERS
  for ((i = 0; i < tries; i++)); do
    cur=$(tmux capture-pane -pt "$pane" 2>/dev/null && printf '.') || cur=""
    cur=${cur%.}
    cy=$(tmux display -pt "$pane" '#{cursor_y}' 2>/dev/null) || cy=""
    rc=0
    pane_has_menu "$cur" "$cy" || rc=$?
    if [ "$rc" -ne 1 ]; then
      cur=""  # a menu, not the input line
    fi
    if [ "$CLI_PANE_HAS_PROMPT_MARKER" -eq 1 ]; then
      if [ -n "$markers" ] && [[ $cur =~ $markers ]] && [ "$cur" = "$prev" ]; then
        return 0
      fi
    elif [ -n "${cur//[[:space:]]/}" ]; then
      if [ "$cur" = "$prev" ]; then stable=$((stable + 1)); else stable=1; fi
      [ "$stable" -lt 3 ] || return 0
    else
      stable=0
    fi
    prev=$cur
    sleep 0.3
  done
  return 1
}

is_peon_session() {
  local session=$1
  [ "$(tmux show-options -qv -t "$session" @peon_code 2>/dev/null || true)" = 1 ]
}
