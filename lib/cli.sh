# shellcheck shell=bash

declare -F cli_call >/dev/null && return 0

CLI_PROVIDERS=()
for cli_file in "$(dirname -- "${BASH_SOURCE[0]}")"/cli/*.sh; do
  [ -f "$cli_file" ] || continue
  # shellcheck disable=SC1090 # Provider files are discovered in this directory.
  source "$cli_file"
  cli_name=${cli_file##*/}
  CLI_PROVIDERS+=("${cli_name%.sh}")
done
unset cli_file cli_name

cli_call() {
  local bin=$1 concern=$2 function
  shift 2
  function="${bin}_$concern"
  if declare -F -- "$function" >/dev/null; then
    "$function" "$@"
    return
  fi
  case $concern in
    launch_command) printf '%s\n' "$1$2 $4" ;;
    resume_id)
      local id=${1##*/}
      id=${id%.jsonl}
      [ -z "$id" ] || printf '%s\n' "$id" ;;
    context_tokens) [ $# -gt 0 ] ;;
    usage_tokens|weekly_limit) return 1 ;;
    *) : ;;
  esac
}

CLI_ALL_PROMPT_MARKERS=""
CLI_ALL_PASTE_PLACEHOLDERS=()
for cli_bin in "${CLI_PROVIDERS[@]}"; do
  cli_marker=$(cli_call "$cli_bin" prompt_marker)
  [ -z "$cli_marker" ] || CLI_ALL_PROMPT_MARKERS="${CLI_ALL_PROMPT_MARKERS:+$CLI_ALL_PROMPT_MARKERS|}$cli_marker"
  cli_pattern=$(cli_call "$cli_bin" paste_placeholder)
  [ -z "$cli_pattern" ] || CLI_ALL_PASTE_PLACEHOLDERS+=("$cli_pattern")
done
unset cli_bin cli_marker cli_pattern

CLI_PROMPT_MARKERS=$CLI_ALL_PROMPT_MARKERS
CLI_PASTE_PLACEHOLDERS=(${CLI_ALL_PASTE_PLACEHOLDERS[@]+"${CLI_ALL_PASTE_PLACEHOLDERS[@]}"})

# Per-call globals let the input awk helpers use the selected pane's provider.
# shellcheck disable=SC2034 # Input and tmux helpers read these globals.
cli_select_pane() {
  local bin marker="" pattern=""
  bin=$(tmux show-options -pqv -t "$1" @peon_bin 2>/dev/null) || bin=""
  CLI_PANE_HAS_PROMPT_MARKER=1
  if [ -n "$bin" ]; then
    marker=$(cli_call "$bin" prompt_marker) || marker=""
    pattern=$(cli_call "$bin" paste_placeholder) || pattern=""
    [ -n "$marker" ] || CLI_PANE_HAS_PROMPT_MARKER=0
  fi
  CLI_PROMPT_MARKERS=${marker:-$CLI_ALL_PROMPT_MARKERS}
  CLI_PASTE_PLACEHOLDERS=(${CLI_ALL_PASTE_PLACEHOLDERS[@]+"${CLI_ALL_PASTE_PLACEHOLDERS[@]}"})
  [ -z "$pattern" ] || CLI_PASTE_PLACEHOLDERS=("$pattern")
  return 0
}
