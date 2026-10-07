# shellcheck shell=bash

# Key tables are server-wide: keep the previous actions for other panes.
enable_mouse_ui() {
  local session=$1 pane name table key fallback action
  local target=()
  tmux set -t "$session" mouse on
  while read -r pane name; do
    [ -n "$name" ] || continue
    tmux set -pt "$pane" @peon_script "$SCRIPT_DIR/peon-code.sh"
  done < <(tmux list-panes -s -t "=$session" -F '#{pane_id} #{@peon_name}')
  [ "$(tmux show-options -sqv @peon_mouse_ui 2>/dev/null || true)" != 1 ] || return 0
  for table in copy-mode copy-mode-vi; do
    for key in MouseDragEnd1Pane MouseDown3Pane M-e; do
      target=()
      [ "$key" = M-e ] || target=(-t '=')
      fallback=$(tmux list-keys -T "$table" "$key" 2>/dev/null || true)
      if [ -z "$fallback" ] && [ "$key" = MouseDown3Pane ]; then
        fallback=$(tmux list-keys -T root "$key" 2>/dev/null || true)
      fi
      fallback=$(printf '%s' "$fallback" | sed -E 's/^bind-key[[:space:]]+(-r[[:space:]]+)?-T[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+//')
      fallback=${fallback:-"run-shell true"}
      if [ "$key" = MouseDragEnd1Pane ]; then
        action='send-keys -X stop-selection ; send-keys -X copy-selection-no-clear'
      else
        action='if-shell -F "#{selection_present}" { send-keys -X copy-pipe-and-cancel "#{q:@peon_script} explain #{pane_id}" } { display-message "Select text first, then right-click or press Alt-e" }'
      fi
      tmux bind-key -T "$table" "$key" if-shell -F ${target[@]+"${target[@]}"} '#{@peon_script}' "$action" "$fallback"
    done
  done
  tmux set-option -s @peon_mouse_ui 1
}

cmd_explain() {
  local pane=${1:-} text result rc=0
  if [ $# -ne 1 ] || [ -z "$pane" ]; then
    die "usage: peon-code.sh explain <pane-id> < selected-text"
  fi
  text=$(cat)
  case $text in
    *[![:space:]]*) ;;
    *) tmux display-message -t "$pane" 'peon-code: no selected text'; return 1 ;;
  esac
  result=$(cmd_send "$pane" $'Explain what the following text means in this conversation:\n\n'"$text" 2>&1) || rc=$?
  printf '%s\n' "$result"
  tmux display-message -t "$pane" -- "${result//#/##}"
  return "$rc"
}
