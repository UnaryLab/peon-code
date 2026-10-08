# shellcheck shell=bash

gemini_launch_command() {
  local BIN=$1 ARGS=$2 RID=$3 Q=$4
  printf '%s\n' "$BIN${RID:+ --resume $RID}$ARGS -i $Q"
}

gemini_trust_project() {
  :
}

# dir and cwd belong to last_thread_file, which calls this in its scope.
# shellcheck disable=SC2034
gemini_resume_dir() {
  local hash
  hash=$(printf '%s' "$PWD" | shasum -a 256 2>/dev/null) ||
    hash=$(printf '%s' "$PWD" | sha256sum 2>/dev/null) || return 0
  dir="$HOME/.gemini/tmp/${hash%% *}/chats"
}

gemini_resume_id() {
  local file=$1 id
  # The first sessionId is the top-level id, before any nested message id.
  id=$(grep -o '"sessionId"[[:space:]]*:[[:space:]]*"[^"]*"' "$file" | head -n 1) || true
  id=${id%\"}
  id=${id##*\"}
  [ -n "$id" ] || return 0
  printf '%s\n' "$id"
}

gemini_context_tokens() {
  [ $# -gt 0 ]
}

gemini_paste_placeholder() {
  :
}

gemini_prompt_marker() {
  :
}
