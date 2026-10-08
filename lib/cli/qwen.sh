# shellcheck shell=bash

qwen_launch_command() {
  local BIN=$1 ARGS=$2 RID=$3 Q=$4
  printf '%s\n' "$BIN${RID:+ --resume $RID}$ARGS -i $Q"
}

qwen_trust_project() {
  :
}

# dir and cwd belong to last_thread_file, which calls this in its scope.
# shellcheck disable=SC2034
qwen_resume_dir() {
  dir="$HOME/.qwen/projects/${PWD//[^A-Za-z0-9]/-}/chats"
}

qwen_resume_id() {
  local file=$1 id
  id=${file##*/}
  id=${id%.jsonl}
  [ -n "$id" ] || return 0
  printf '%s\n' "$id"
}

qwen_context_tokens() {
  [ $# -gt 0 ]
}

qwen_paste_placeholder() {
  :
}

qwen_prompt_marker() {
  :
}
