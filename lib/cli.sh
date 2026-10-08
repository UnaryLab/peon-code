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
    *) : ;;
  esac
}

CLI_PROMPT_MARKERS=""
CLI_PASTE_PLACEHOLDERS=()
for cli_bin in "${CLI_PROVIDERS[@]}"; do
  cli_marker=$(cli_call "$cli_bin" prompt_marker)
  [ -z "$cli_marker" ] || CLI_PROMPT_MARKERS="${CLI_PROMPT_MARKERS:+$CLI_PROMPT_MARKERS|}$cli_marker"
  cli_pattern=$(cli_call "$cli_bin" paste_placeholder)
  [ -z "$cli_pattern" ] || CLI_PASTE_PLACEHOLDERS+=("$cli_pattern")
done
unset cli_bin cli_marker cli_pattern
