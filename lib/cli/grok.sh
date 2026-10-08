# shellcheck shell=bash

grok_launch_command() {
  local BIN=$1 ARGS=$2 RID=$3 Q=$4
  printf '%s\n' "$BIN${RID:+ --resume $RID}$ARGS $Q"
}

grok_trust_project() {
  :
}

# dir and cwd belong to last_thread_file, which calls this in its scope.
# shellcheck disable=SC2034
grok_resume_dir() {
  dir="$HOME/.grok/sessions/$(url_encode "$PWD")"
}

grok_resume_id() {
  local file=$1 id
  id=${file%/*}
  id=${id##*/}
  [ -n "$id" ] || return 0
  printf '%s\n' "$id"
}

grok_context_tokens() {
  [ $# -gt 0 ]
}

grok_paste_placeholder() {
  printf '%s\n' '^\[Pasted: [0-9]+ lines?\]$'
}

grok_prompt_marker() {
  :
}
