# shellcheck shell=bash

claude_launch_command() {
  local BIN=$1 ARGS=$2 RID=$3 i=$5
  local SETTINGS
  # A pane's own --settings wins over the generated settings:
  # claude reads one --settings and the second would be lost.
  SETTINGS=""
  case "$ARGS " in
    *" --settings "*|*" --settings="*)
      echo "peon-code: ${NAMES[$i]} passes its own --settings, so it may stay fullscreen" >&2
      if [ "$i" -ne "$MAIN" ]; then
        echo "peon-code: ${NAMES[$i]} passes its own --settings, so it gets no git deny file" >&2
      fi ;;
    *)
      if [ "$i" -eq "$MAIN" ]; then SETTINGS=" --settings $(printf %q "$NORMAL_SETTINGS")"
      else SETTINGS=" --settings $(printf %q "$DENY_SETTINGS")"; fi ;;
  esac
  if [ "$i" -ne "$MAIN" ]; then
    case "$ARGS " in
      *" --dangerously-skip-permissions "*)
        echo "peon-code: ${NAMES[$i]} passes --dangerously-skip-permissions, so the git deny file has no effect" >&2 ;;
    esac
  fi
  printf '%s\n' "$BIN${RID:+ --resume $RID}$ARGS$SETTINGS"
}

claude_trust_project() {
  local claude_config
  local project_dirs=("$@")
  claude_config="${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json"
  if [ ! -f "$claude_config" ] || ! command -v python3 >/dev/null 2>&1; then
    echo "peon-code: skipping Claude project trust: existing $claude_config and python3 are required" >&2
  elif ! python3 - "$claude_config" "${project_dirs[@]}" 2>/dev/null <<'PYTHON'
import json
import os
import stat
import sys
import tempfile

config, *projects = sys.argv[1:]
config = os.path.realpath(config)
temporary = None
try:
    mode = stat.S_IMODE(os.stat(config).st_mode)
    with open(config, encoding="utf-8") as file:
        data = json.load(file)
    entries = data.setdefault("projects", {})
    changed = False
    for project in projects:
        entry = entries.setdefault(project, {})
        if entry.get("hasTrustDialogAccepted") is not True:
            entry["hasTrustDialogAccepted"] = True
            changed = True
    if not changed:
        sys.exit(0)
    fd, temporary = tempfile.mkstemp(prefix=".claude-trust.", dir=os.path.dirname(config))
    with os.fdopen(fd, "w", encoding="utf-8") as file:
        json.dump(data, file, indent=2)
        file.write("\n")
        os.fchmod(file.fileno(), mode)
    os.replace(temporary, config)
    temporary = None
finally:
    if temporary is not None:
        os.unlink(temporary)
PYTHON
  then
    echo "peon-code: could not set Claude project trust in $claude_config; kept the original file" >&2
  fi
}

# dir and cwd belong to last_thread_file, which calls this in its scope.
# shellcheck disable=SC2034
claude_resume_dir() {
  dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/${PWD//[^A-Za-z0-9]/-}"
}

claude_resume_id() {
  local file=$1 id
  id=${file##*/}
  id=${id%.jsonl}
  [ -n "$id" ] || return 0
  printf '%s\n' "$id"
}

claude_context_tokens() {
  [ $# -gt 0 ] || return 0
  local file=$1 rec a b c
  # Each assistant message carries the API usage: the input plus both
  # cache fields is the full context of that request.
  rec=$(grep -o '"usage":{[^}]*}' "$file" 2>/dev/null | tail -n 1) || true
  [ -n "$rec" ] || return 0
  a=$(printf '%s' "$rec" | sed -n 's/.*"input_tokens":\([0-9]*\).*/\1/p')
  b=$(printf '%s' "$rec" | sed -n 's/.*"cache_creation_input_tokens":\([0-9]*\).*/\1/p')
  c=$(printf '%s' "$rec" | sed -n 's/.*"cache_read_input_tokens":\([0-9]*\).*/\1/p')
  [ -n "$a" ] || return 0
  echo $((a + ${b:-0} + ${c:-0}))
}

claude_paste_placeholder() {
  printf '%s\n' '^\[Pasted text #[0-9]+( \+[0-9]+ lines)?\]$'
}

claude_prompt_marker() {
  printf '\342\235\257'
}

claude_brief_after_start() {
  # A resumed pane may open on the summary picker; take its default,
  # "Resume from summary", then allow for the compaction that starts:
  # 400 settle tries (~2 min) instead of the usual 100.
  [ -z "$RID" ] || answer_dialog "${PANE_IDS[$i]}" "*Resume from summary*"
  # An unsettled pane is showing a dialog or still starting; pasting there
  # would answer the dialog blindly, which the brief tells agents never to do.
  if wait_pane_settled "${PANE_IDS[$i]}" "${RID:+400}"; then
    PASTE_RC=0
    printf '%s' "$BRIEF" | paste_to_pane "${PANE_IDS[$i]}" || PASTE_RC=$?
    case $PASTE_RC in
      1) echo "peon-code: tmux refused the brief for ${NAMES[$i]} ${PANE_IDS[$i]}. Send it with: peon-code rebrief ${NAMES[$i]}" >&2 ;;
      3|75) echo "peon-code: no brief sent: input or another delivery is busy for ${NAMES[$i]} ${PANE_IDS[$i]}" >&2 ;;
      2) echo "peon-code: no Enter sent to ${NAMES[$i]} ${PANE_IDS[$i]}: the brief is in its box for you to submit" >&2 ;;
    esac
  else
    echo "peon-code: ${NAMES[$i]} is still on a dialog or starting up. Answer it, then run: peon-code rebrief ${NAMES[$i]}" >&2
  fi
}
