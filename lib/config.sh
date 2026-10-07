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

# A role file opens with a frontmatter block (--- lines) holding type: and
# description:. role_field prints one key's
# value, empty when the file or key is missing; role_body prints the file
# without the block. The type (manager, worker, reviewer) picks the agent's
# duties in roles/protocol.md; the body holds only the domain rules.
role_field() {
  local path=$1 key=$2
  [ -f "$path" ] || return 0
  [ "$(sed -n 1p "$path")" = "---" ] || return 0
  sed -n '2,/^---$/p' "$path" | sed -n "s/^$key:[[:space:]]*//p" | head -1
}

role_body() {
  awk 'NR == 1 && $0 == "---" { skip = 1; next } skip && $0 == "---" { skip = 0; next } !skip' "$1"
}

# The protocol file sliced for one type: every section stays except the
# "## <Type> duties" sections of the other types, so a brief carries the
# role types, the board rules, the message table, and its own duties.
protocol_for() {
  awk -v type="$1" '
    /^## / { keep = 1; if ($0 ~ / duties$/) keep = (tolower($2) == type) }
    keep' "$SCRIPT_DIR/roles/protocol.md"
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
    # The one setting line: "compact-at <tokens>" is the context size at
    # which the watcher compacts a pane; 0 turns the watcher off.
    if [ "${tokens[0]}" = compact-at ]; then
      [ "$n" -eq 2 ] && [[ ${tokens[1]} =~ ^[0-9]+$ ]] ||
        die "$conf line $lineno: compact-at takes one number of tokens: $line"
      COMPACT_AT=${tokens[1]}
      continue
    fi
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
    if [ -n "$path" ]; then
      case $(role_field "$path" type) in
        manager|worker|reviewer) ;;
        *) die "$conf line $lineno: role file $path needs a frontmatter type: manager, worker, or reviewer" ;;
      esac
    fi
    NAMES+=("$name")
    CMDS+=("$cmd")
    ROLES+=("$path")
  done <"$conf"
  [ ${#NAMES[@]} -gt 0 ] || die "$conf has no agents"
  # A team that uses roles needs a manager, a worker, and a reviewer: the
  # protocol routes every task through the manager, every completion to the
  # reviewer, and every row to a worker. A roleless CLI team coordinates
  # nothing and skips the check.
  local has_role=0 has_manager=0 has_worker=0 has_reviewer=0
  for path in ${ROLES[@]+"${ROLES[@]}"}; do
    [ -n "$path" ] || continue
    has_role=1
    case $(role_field "$path" type) in
      manager) has_manager=1 ;;
      worker)  has_worker=1 ;;
      reviewer) has_reviewer=1 ;;
    esac
  done
  if [ "$has_role" -eq 1 ]; then
    [ "$has_manager" -eq 1 ] || die "$conf: a team with roles needs a manager-type role"
    [ "$has_worker" -eq 1 ] || die "$conf: a team with roles needs a worker-type role"
    [ "$has_reviewer" -eq 1 ] || die "$conf: a team with roles needs a reviewer-type role"
  fi
}

load_team() {
  local arg
  NAMES=()
  CMDS=()
  ROLES=()
  MAIN_INDEX=-1
  COMPACT_AT=250000
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

# Offer a pull when the checkout behind SCRIPT_DIR is behind its upstream.
# The comparison uses the refs the last fetch left, and a new fetch runs in the
# background so a start never waits on the network; a push lands in the offer
# one start late. A checkout with no upstream, or no git, says nothing. Returns
# 0 only after a pull, so the caller can restart on the new code; headless
# stdin (EOF) counts as no.
offer_update() {
  local behind reply machine
  git -C "$SCRIPT_DIR" rev-parse --verify -q '@{u}' >/dev/null 2>&1 || return 1
  behind=$(git -C "$SCRIPT_DIR" rev-list --count 'HEAD..@{u}' 2>/dev/null) || return 1
  if [ "${behind:-0}" -eq 0 ]; then
    (git -C "$SCRIPT_DIR" fetch -q >/dev/null 2>&1 &)  # for the next start
    return 1
  fi
  machine=$(hostname 2>/dev/null | LC_ALL=C tr -cd 'A-Za-z0-9._-') || machine=unknown
  machine=${machine:0:255}
  machine=${machine:-unknown}
  if [ "${1:-}" = stdio ]; then
    printf '{"update":%s,"host":"%s"}\n' "$behind" "$machine"
  else
    printf 'peon-code: %s new commit(s) upstream; pull now? [y/N] [%s] ' "$behind" "$machine" >&2
  fi
  read -r reply || reply=n
  case $reply in
    [yY]|[yY][eE][sS])
      if ! git -C "$SCRIPT_DIR" pull -q --ff-only; then
        echo "peon-code: update failed on $machine; starting current version" >&2
        return 1
      fi
      # Held on screen so the restart does not wipe the pull's outcome unseen.
      echo "peon-code: updated; starting on $machine" >&2
      sleep "${PEON_UPDATE_PAUSE:-3}" ;;
    *) echo "peon-code: not updated; later: git -C $SCRIPT_DIR pull (host: $machine)" >&2; return 1 ;;
  esac
}
