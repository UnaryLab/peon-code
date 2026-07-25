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
