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
    # Optional concerns: own_thread, child_threads, resume_args, quit_command, probe_command, swap_args, usage_tokens, weekly_limit.
    own_thread) return 0 ;;
    child_threads|resume_args|quit_command|probe_command|swap_args|usage_tokens|weekly_limit) return 1 ;;
    *) : ;;
  esac
}

# Provider ancestry keeps Claude totals within the owning session's child directory.
cli_usage_sum() {
  local bin=$1 own=$2 usage children child path duplicate input read_cache write_cache output a b c d
  local seen=("$own")
  usage=$(cli_call "$bin" usage_tokens "$own") || return 0
  [[ $usage =~ ^[0-9]+\ [0-9]+\ [0-9]+\ [0-9]+$ ]] || return 0
  read -r input read_cache write_cache output <<<"$usage"
  input=$((10#$input)); read_cache=$((10#$read_cache)); write_cache=$((10#$write_cache)); output=$((10#$output))
  children=$(cli_call "$bin" child_threads "$own") || children=""
  while IFS= read -r child; do
    [ -n "$child" ] || continue
    duplicate=0
    for path in "${seen[@]}"; do [ "$path" != "$child" ] || duplicate=1; done
    [ "$duplicate" = 0 ] || continue
    seen+=("$child")
    usage=$(cli_call "$bin" usage_tokens "$child") || continue
    [[ $usage =~ ^[0-9]+\ [0-9]+\ [0-9]+\ [0-9]+$ ]] || continue
    read -r a b c d <<<"$usage"
    input=$((input + 10#$a))
    read_cache=$((read_cache + 10#$b))
    write_cache=$((write_cache + 10#$c))
    output=$((output + 10#$d))
  done <<<"$children"
  printf '%s %s %s %s\n' "$input" "$read_cache" "$write_cache" "$output"
}

# Keep stored shell words literal; only provider model and effort flags are replaced.
cli_swap_args() {
  SWAP_ARGS=$1 SWAP_MODEL=$2 SWAP_EFFORT=$3 SWAP_PROVIDER=$4 awk '
    function token(start, pos, ch, nextch, depth, quote) {
      depth = 0; quotes[0] = ""; word = ""
      for (pos = start; pos <= length(args); pos++) {
        ch = substr(args, pos, 1); nextch = substr(args, pos + 1, 1)
        quote = quotes[depth]
        if (depth == 0 && quote == "" && ch ~ /[[:space:]]/) break
        if (ch == "\\" && quote != "\047") {
          word = word nextch; pos++; continue
        }
        if (quote == "\047") {
          if (ch == quote) quotes[depth] = ""
          else word = word ch
          continue
        }
        if (ch == "$" && (nextch == "(" || nextch == "{")) {
          word = word ch nextch; depth++; closes[depth] = nextch == "(" ? ")" : "}"
          quotes[depth] = ""; pos++; continue
        }
        if (ch == "`" && depth > 0 && closes[depth] == "`" && quote == "") {
          word = word ch; depth--; continue
        }
        if (ch == "`") {
          word = word ch; depth++; closes[depth] = "`"; quotes[depth] = ""; continue
        }
        if (quote == "\042") {
          if (ch == quote) quotes[depth] = ""
          else word = word ch
          continue
        }
        if (ch == "\047" || ch == "\042") { quotes[depth] = ch; continue }
        if (depth > 0 && ch == closes[depth]) { word = word ch; depth--; continue }
        if (depth > 0 && closes[depth] == ")" && ch == "(") {
          word = word ch; depth++; closes[depth] = ")"; quotes[depth] = ""; continue
        }
        word = word ch
      }
      end = pos
    }
    BEGIN {
      args = ENVIRON["SWAP_ARGS"]; model = ENVIRON["SWAP_MODEL"]
      effort = ENVIRON["SWAP_EFFORT"]; provider = ENVIRON["SWAP_PROVIDER"]
      pos = 1; count = 0
      while (pos <= length(args)) {
        prefix = pos
        while (substr(args, pos, 1) ~ /[[:space:]]/) pos++
        if (pos > length(args)) { trailing = substr(args, prefix); break }
        token(pos)
        count++; words[count] = word; raw[count] = substr(args, prefix, end - prefix)
        pos = end
      }
      result = ""
      for (i = 1; i <= count; i++) {
        if (model != "-" && (words[i] == "--model" || (provider == "codex" && words[i] == "-m"))) { i++; continue }
        if (model != "-" && (index(words[i], "--model=") == 1 || (provider == "codex" && index(words[i], "-m=") == 1))) continue
        if (effort != "-" && provider == "claude" && words[i] == "--effort") { i++; continue }
        if (effort != "-" && provider == "claude" && index(words[i], "--effort=") == 1) continue
        if (effort != "-" && provider == "codex") {
          if ((words[i] == "-c" || words[i] == "--config") && index(words[i+1], "model_reasoning_effort=") == 1) { i++; continue }
          if (index(words[i], "--config=model_reasoning_effort=") == 1 || index(words[i], "-c=model_reasoning_effort=") == 1) continue
        }
        result = result raw[i]
      }
      result = result trailing
      if (model != "-") result = result " --model " model
      if (effort != "-") result = result (provider == "claude" ? " --effort " : " -c model_reasoning_effort=") effort
      printf "%s", result
    }
  '
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
