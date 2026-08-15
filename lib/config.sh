# shellcheck shell=bash

# Role token: - is none, a token with / is a path (relative to the config
# file's directory), a bare name is <script dir>/roles/<name>.md.
resolve_role() {
  local role=$1 conf_dir=$2
  case $role in
    -)   echo "" ;;
    /*)  echo "$role" ;;
    */*) echo "$conf_dir/$role" ;;
    *)   echo "$SCRIPT_DIR/roles/$role.md" ;;
  esac
}

role_label() {
  local path=$1 base
  [ -n "$path" ] || { echo "none"; return; }
  base=${path##*/}
  echo "${base%.md}"
}

# Percent-encode a string the way JavaScript encodeURIComponent does: keep
# A-Za-z0-9 and - _ . ~ literal, encode every other byte as uppercase %XX.
# grok names each per-directory session store by this encoding of the path
# (/ -> %2F, space -> %20). LC_ALL=C makes the loop step one byte at a time,
# so a multibyte path encodes its UTF-8 bytes.
# ponytail: the unreserved set omits encodeURIComponent's ! ~ * ' ( ); a path
# holding those would misencode and just miss the resume, add them if it bites.
url_encode() {
  local s=$1 out="" c i LC_ALL=C
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case $c in
      [A-Za-z0-9._~-]) out=$out$c ;;
      *) out=$out$(printf '%%%02X' "'$c") ;;
    esac
  done
  printf '%s' "$out"
}

# Previous thread of one agent, found by the marker phrase its brief carries:
# the phrase names the agent and the session, and the CLIs record the prompt
# in their transcript, so no launch-time bookkeeping is needed. Newest match
# wins; empty output means there is nothing to resume and the pane starts new.
# The search is capped at 30 days of transcripts, the age past which
# a thread is not worth reviving.
last_thread_id() {
  local marker=$1 bin=$2 dir cwd="" hash found file id
  case $bin in
    claude)  dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/${PWD//[^A-Za-z0-9]/-}" ;;
    codex)   dir="${CODEX_HOME:-$HOME/.codex}/sessions"
             # Rollouts of every directory share this store; a match must also
             # carry the cwd line naming this directory.
             cwd="\"cwd\":\"$PWD\"" ;;
    copilot) dir="$HOME/.copilot/session-state"
             # Session logs of every directory share this store; a match must
             # also carry the cwd line naming this directory.
             cwd="\"cwd\":\"$PWD\"" ;;
    gemini)  # gemini keys its per-directory store by the SHA-256 of the path
             hash=$(printf '%s' "$PWD" | shasum -a 256 2>/dev/null) ||
               hash=$(printf '%s' "$PWD" | sha256sum 2>/dev/null) || return 0
             dir="$HOME/.gemini/tmp/${hash%% *}/chats" ;;
    qwen)    dir="$HOME/.qwen/projects/${PWD//[^A-Za-z0-9]/-}/chats" ;;
    grok)    # grok keys its per-directory store by url-encoding the path,
             # so this dir already scopes to the cwd and needs no cwd match.
             dir="$HOME/.grok/sessions/$(url_encode "$PWD")" ;;
    *) return 0 ;;  # no known transcript store, so no resume handle
  esac
  [ -d "$dir" ] || return 0
  # Checked before sorting: with no input, xargs still runs ls, which would
  # then list the working directory instead of transcripts.
  found=$(find "$dir" -name '*.jsonl' -type f -mtime -30 2>/dev/null) || true
  [ -n "$found" ] || return 0
  while IFS= read -r file; do
    grep -qF -- "$marker" "$file" || continue
    [ -z "$cwd" ] || grep -qF -- "$cwd" "$file" || continue
    case $bin in
      copilot|grok) id=${file%/*}     # <id>/*.jsonl: the directory is the id
               id=${id##*/} ;;
      gemini)  # the filename holds 8 chars of the id; the body holds it all.
               # First occurrence in file order: the top-level sessionId comes
               # before any sessionId nested inside a message.
               id=$(grep -o '"sessionId"[[:space:]]*:[[:space:]]*"[^"]*"' "$file" | head -n 1) || true
               id=${id%\"}
               id=${id##*\"} ;;
      codex)   id=${file##*/}
               id=${id%.jsonl}
               id=${id: -36} ;;       # rollout-<timestamp>-<id>.jsonl
      *)       id=${file##*/}
               id=${id%.jsonl} ;;     # claude and qwen name the file by the id
    esac
    [ -n "$id" ] || continue
    printf '%s\n' "$id"
    return 0
  done < <(printf '%s\n' "$found" | tr '\n' '\0' | xargs -0 ls -t 2>/dev/null)
}

read_conf() {
  local conf=$1 conf_dir line lineno=0 n name cmd role path known
  conf_dir=$(cd -- "$(dirname -- "$conf")" && pwd)
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
    local tokens=()
    read -ra tokens <<<"$line"
    n=${#tokens[@]}
    [ "$n" -ge 3 ] || die "$conf line $lineno: need name, command, and role (got $n): $line"
    name=${tokens[0]}
    # A leading * marks the main agent: its pane gets the big left slot.
    if [[ $name == \** ]]; then
      name=${name#\*}
      [ "$MAIN_INDEX" -lt 0 ] || die "$conf line $lineno: a second agent is marked main with *"
      MAIN_INDEX=${#NAMES[@]}
    fi
    role=${tokens[$((n - 1))]}
    cmd="${tokens[*]:1:$((n - 2))}"
    [[ $name =~ ^[A-Za-z0-9_-]+$ ]] || die "$conf line $lineno: name \"$name\" must be letters, digits, _ or -"
    for known in ${NAMES[@]+"${NAMES[@]}"}; do
      if [ "$known" = "$name" ]; then
        die "$conf line $lineno: name \"$name\" is used twice"
      fi
    done
    path=$(resolve_role "$role" "$conf_dir")
    [ -z "$path" ] || [ -f "$path" ] || die "$conf line $lineno: role file not found: $path"
    NAMES+=("$name")
    CMDS+=("$cmd")
    ROLES+=("$path")
  done <"$conf"
  [ ${#NAMES[@]} -gt 0 ] || die "$conf has no agents"
}

load_team() {
  local arg
  NAMES=()
  CMDS=()
  ROLES=()
  MAIN_INDEX=-1
  if [ $# -gt 0 ]; then
    # CLI agent commands win; the name is the command string, no role.
    for arg in "$@"; do
      case $arg in
        -*) die "agent command \"$arg\" starts with -; put options before the session name" ;;
      esac
      NAMES+=("$arg")
      CMDS+=("$arg")
      ROLES+=("")
    done
    return
  fi

  # Resolution: ./peon-code.conf, then the user fallback, then claude codex.
  if [ -z "$CONF" ]; then
    CONF=$DEFAULT_CONF
    [ -f "$CONF" ] || CONF="$HOME/.config/peon-code/peon-code.conf"
  fi
  if [ -f "$CONF" ]; then
    read_conf "$CONF"
  elif [ "$CONF_GIVEN" -eq 1 ]; then
    die "config file not found: $CONF"
  else
    for arg in claude codex; do
      NAMES+=("$arg")
      CMDS+=("$arg")
      ROLES+=("")
    done
  fi
}
