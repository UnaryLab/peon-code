# shellcheck shell=bash

copilot_launch_command() {
  local BIN=$1 ARGS=$2 RID=$3 Q=$4
  printf '%s\n' "$BIN${RID:+ --resume=$RID}$ARGS -i $Q"
}

copilot_trust_project() {
  :
}

# dir and cwd belong to last_thread_file, which calls this in its scope.
# shellcheck disable=SC2034
copilot_resume_dir() {
  dir="$HOME/.copilot/session-state"
  cwd="\"cwd\":\"$PWD\""
}

copilot_resume_id() {
  local file=$1 id
  id=${file%/*}
  id=${id##*/}
  [ -n "$id" ] || return 0
  printf '%s\n' "$id"
}

copilot_context_tokens() {
  [ $# -gt 0 ]
}

copilot_paste_placeholder() {
  printf '%s\n' '^\[Paste #[0-9]+( - [0-9]+ lines)?\]$'
}

copilot_prompt_marker() {
  :
}
