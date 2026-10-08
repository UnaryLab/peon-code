# shellcheck shell=bash

# shellcheck source=lib/cli.sh
declare -F cli_call >/dev/null || source "$(dirname -- "${BASH_SOURCE[0]}")/cli.sh"

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
  local marker=$1 bin=$2 file
  file=$(last_thread_file "$marker" "$bin") || return 0
  [ -n "$file" ] || return 0
  cli_call "$bin" resume_id "$file"
}

# The newest transcript file carrying the marker, or nothing. Shared by the
# resume lookup and the context watcher. An optional reference file limits
# the search to transcripts modified after its timestamp.
last_thread_file() {
  local marker=$1 bin=$2 ref=${3:-} dir="" cwd="" found file
  cli_call "$bin" resume_dir
  [ -d "$dir" ] || return 0
  # Checked before sorting: with no input, xargs still runs ls, which would
  # then list the working directory instead of transcripts.
  set -- "$dir" -name '*.jsonl' -type f -mtime -30
  [ -z "$ref" ] || set -- "$@" -newer "$ref"
  found=$(find "$@" 2>/dev/null) || true
  [ -n "$found" ] || return 0
  while IFS= read -r file; do
    grep -qF -- "$marker" "$file" || continue
    [ -z "$cwd" ] || grep -qF -- "$cwd" "$file" || continue
    printf '%s\n' "$file"
    return 0
  done < <(printf '%s\n' "$found" | tr '\n' '\0' | xargs -0 ls -t 2>/dev/null)
}
