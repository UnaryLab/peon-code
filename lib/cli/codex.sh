# shellcheck shell=bash

codex_launch_command() {
  local BIN=$1 ARGS=$2 RID=$3 Q=$4
  case "$ARGS " in
    *" --no-alt-screen "*) ;;
    *) ARGS="$ARGS --no-alt-screen" ;;
  esac
  printf '%s\n' "$BIN${RID:+ resume $RID}$ARGS $Q"
}

codex_trust_project() {
  local codex_config codex_temp codex_link links project_path project_key header
  local project_dirs=("$@")
  codex_config="${CODEX_HOME:-$HOME/.codex}/config.toml"
  links=0
  while [ -L "$codex_config" ]; do
    if [ "$links" -ge 40 ] || ! codex_link=$(readlink "$codex_config"); then
      echo "peon-code: could not resolve Codex config link $codex_config; skipping project trust" >&2
      codex_config=""
      break
    fi
    case $codex_link in
      /*) codex_config=$codex_link ;;
      *) codex_config=${codex_config%/*}/$codex_link ;;
    esac
    links=$((links + 1))
  done
  [ -n "$codex_config" ] || return 0
  if [ -f "$codex_config" ] &&
    grep -Eq "^[[:space:]]*[\"']?projects[\"']?[[:space:]]*=" "$codex_config"; then
    echo 'peon-code: config.toml has an inline projects table; skipping codex project trust' >&2
    return 0
  fi
  for project_path in "${project_dirs[@]}"; do
    project_key=${project_path//\\/\\\\}
    project_key=${project_key//\"/\\\"}
    project_key=${project_key//$'\n'/\\n}
    project_key=${project_key//$'\r'/\\r}
    project_key=${project_key//$'\t'/\\t}
    header="[projects.\"$project_key\"]"
    if [ -f "$codex_config" ] && {
      grep -Fq -- "\"$project_key\"" "$codex_config" || {
        [[ $project_path != *$'\n'* && $project_path != *$'\r'* && $project_path != *"'"* ]] &&
          grep -Fq -- "'$project_path'" "$codex_config"
      }
    }; then
      continue
    fi
    if ! mkdir -p "${codex_config%/*}" ||
      ! codex_temp=$(mktemp "${codex_config%/*}/.peon-code-trust.XXXXXX"); then
      echo "peon-code: could not prepare Codex project trust in $codex_config" >&2
      break
    fi
    if {
      if [ -f "$codex_config" ]; then
        cp -p "$codex_config" "$codex_temp" &&
          printf '\n\n%s\n%s\n' "$header" 'trust_level = "trusted"' >>"$codex_temp"
      else
        printf '%s\n%s\n' "$header" 'trust_level = "trusted"' >"$codex_temp"
      fi
    } && mv "$codex_temp" "$codex_config"; then
      :
    else
      echo "peon-code: could not set Codex project trust in $codex_config; kept the original file" >&2
      break
    fi
  done
}

# dir and cwd belong to last_thread_file, which calls this in its scope.
# shellcheck disable=SC2034
codex_resume_dir() {
  dir="${CODEX_HOME:-$HOME/.codex}/sessions"
  cwd="\"cwd\":\"$PWD\""
}

codex_resume_id() {
  local file=$1 id
  id=${file##*/}
  id=${id%.jsonl}
  id=${id: -36}
  [ -n "$id" ] || return 0
  printf '%s\n' "$id"
}

codex_context_tokens() {
  [ $# -gt 0 ] || return 0
  local file=$1 rec
  # Each turn ends with a token_count event; last_token_usage.input_tokens
  # is the context of the last request.
  rec=$(grep -o '"last_token_usage":{"input_tokens":[0-9]*' "$file" 2>/dev/null | tail -n 1) || true
  [ -n "$rec" ] || return 0
  echo "${rec##*:}"
}

codex_usage_tokens() {
  [ $# -gt 0 ] || return 0
  [ -f "$1" ] && [ -r "$1" ] || return 0
  awk '
    function token(record, key, value) {
      if (!match(record, "\"" key "\"[[:space:]]*:[[:space:]]*[0-9]+[[:space:]]*[,}]")) return ""
      value = substr(record, RSTART, RLENGTH)
      sub(/^[^:]*:[[:space:]]*/, "", value)
      sub(/[[:space:]]*[,}]$/, "", value)
      return value
    }
    match($0, /"total_token_usage"[[:space:]]*:[[:space:]]*\{[^}]*\}/) {
      record = substr($0, RSTART, RLENGTH)
    }
    END {
      input = token(record, "input_tokens"); output = token(record, "output_tokens")
      if (input == "" || output == "") exit
      read = token(record, "cached_input_tokens") + 0
      if (read > input + 0) exit
      printf "%.0f %.0f %.0f %.0f\n", input - read, read, token(record, "cache_write_input_tokens"), output
    }
  ' "$1" 2>/dev/null || true
}

codex_weekly_limit() {
  [ $# -gt 0 ] || return 0
  [ -f "$1" ] && [ -r "$1" ] || return 0
  LC_ALL=C awk '
    function number(record, key, value) {
      if (!match(record, "\"" key "\"[[:space:]]*:[[:space:]]*[0-9]+([.][0-9]+)?[[:space:]]*[,}]")) return ""
      value = substr(record, RSTART, RLENGTH)
      sub(/^[^:]*:[[:space:]]*/, "", value)
      sub(/[[:space:]]*[,}]$/, "", value)
      return value
    }
    /"type"[[:space:]]*:[[:space:]]*"token_count"/ { last = $0 }
    END {
      if (!match(last, /"rate_limits"[[:space:]]*:[[:space:]]*\{/)) exit
      limits = substr(last, RSTART)
      for (i = 1; i <= 2; i++) {
        key = i == 1 ? "primary" : "secondary"
        if (!match(limits, "\"" key "\"[[:space:]]*:[[:space:]]*\\{[^}]*\\}")) continue
        record = substr(limits, RSTART, RLENGTH)
        if (number(record, "window_minutes") != "10080") continue
        used = number(record, "used_percent"); resets = number(record, "resets_at")
        if (used == "" || resets !~ /^[0-9]+$/) continue
        printf "%.1f %.0f\n", (used + 0 > 100 ? 100 : used), resets
        exit
      }
    }
  ' "$1" 2>/dev/null || true
}

codex_paste_placeholder() {
  printf '%s\n' '^\[Pasted Content [0-9]+ chars\]$'
}

codex_prompt_marker() {
  printf '\342\200\272'
}
