#!/usr/bin/env bash
# Start a tmux session of collaborating AI coding agents, one per pane,
# each launched with a prompt telling it to watch the other panes.
# Usage:
#   ./peon-code.sh [-c file] [<session>] [<cmd> ...]
#   ./peon-code.sh resume [<session>] [<cmd> ...]
#   ./peon-code.sh dismiss [<session>]
#   ./peon-code.sh msg <name|all> 'text' [<session>]
#   ./peon-code.sh send <pane-id> 'text'|-
#   ./peon-code.sh key <pane-id> <name>
#   ./peon-code.sh explain <pane-id> < selected-text
#   ./peon-code.sh rebrief <name|all> [<session>]
#   ./peon-code.sh compact [<name|all>] [<session>]
#   ./peon-code.sh clear [<name|all>] [<session>]
#   ./peon-code.sh watch [<session>] [<tokens>]
#   ./peon-code.sh list
#   ./peon-code.sh uninstall [bin-dir]
#   ./peon-code.sh -h
# Team resolution: CLI agent commands > -c file > ./peon-code.conf >
# ~/.config/peon-code/peon-code.conf > claude codex.
# Known agents get the right "interactive session + initial prompt" launch:
#   claude          launched bare, brief pasted in once its TUI is up; resumes with --resume <id>,
#                   answering a "Resume from summary" picker with its summary default
#   codex           positional prompt, stays interactive; resumes with resume <id>
#   copilot         -i <prompt>  (verified on this machine); resumes with --resume=<id>
#   grok            positional prompt, stays interactive (verified on this machine); resumes with --resume <id>
#   gemini, qwen    -i <prompt>  (documented; unverified on this machine); resume with --resume <id>
# Any other command is passed through as-is: <cmd> <quoted-brief>.
# The session is attached first and the CLIs start while it is on screen, their
# launch notes arriving as tmux status-line messages. A pane opening on the
# folder-trust check is left for you to answer in the attached session.
set -euo pipefail

# Resolve symlinks without readlink -f, which macOS lacks before 12.3.
script_path=${BASH_SOURCE[0]}
while [ -L "$script_path" ]; do
  link_target=$(readlink "$script_path")
  case $link_target in
    /*) script_path=$link_target ;;
    *)  script_path=$(dirname -- "$script_path")/$link_target ;;
  esac
done
SCRIPT_DIR=$(cd -- "$(dirname -- "$script_path")" && pwd)
DEFAULT_CONF=peon-code.conf
TASK_BOARD=.peon-code-task.md
WRITER_DIR=innovation_summary

usage() {
  cat <<'USAGE'
peon-code.sh [-c file] [<session>] [<cmd> ...]  start or attach a team
                                                (session defaults to the current directory name)
peon-code.sh resume [<session>] [<cmd> ...]     same, each agent reopening its last
                                                conversation (claude, codex, copilot,
                                                grok, gemini, qwen)
peon-code.sh dismiss [<session>]                kill one session
                                                (session defaults to the current directory name)
peon-code.sh detach [<session>]                 detach every client of one session, leaving
                                                it and its agents running
                                                (session defaults to the current directory name)
peon-code.sh msg <name|all> 'text' [<session>]  send text to an agent pane
                                                (session defaults to the current directory name)
peon-code.sh send <pane-id> 'text'|-            agent to agent: paste into a pane and
                                                submit it; a blocked pane (typed text,
                                                dialog, menu, copy mode) is retried up
                                                to 10 times over ~10s before exiting
                                                non-zero (- reads the message from stdin)
peon-code.sh explain <pane-id>                 explain selected text from stdin in the same pane
peon-code.sh key <pane-id> <name>              press Tab, Up, Down, Escape, or 1..9;
                                                Enter is allowed only on a menu
peon-code.sh rebrief <name|all> [<session>]     send an agent its launch brief again,
                                                for after it compacts its conversation
                                                (session defaults to the current directory name)
peon-code.sh compact [<name|all>] [<session>]   send /compact to an agent pane, then send
                                                its brief again once compaction ends,
                                                skipping any blocked pane (typed text,
                                                dialog, menu, copy mode)
                                                (name and session default to all and the
                                                current directory name)
peon-code.sh clear [<name|all>] [<session>]     send /clear to an agent pane, then send
                                                its brief again, skipping any blocked
                                                pane (typed text, dialog, menu, copy mode)
                                                (name and session default to all and the
                                                current directory name)
peon-code.sh watch [<session>] [<tokens>]      compact an agent pane whose context reaches
                                                <tokens> (default 250000), checked once a
                                                minute from its transcript; started by
                                                every launch, so run it by hand only
                                                after killing that one
peon-code.sh list                               agent panes of every session
peon-code.sh uninstall [bin-dir]                remove both installed command symlinks
peon-code.sh -h                                 this help

  -c file   agent config file (default ./peon-code.conf, then
            ~/.config/peon-code/peon-code.conf, if present)

Config file: one agent per line, "name command... role".
The role is required; use - for no role. A bare role name reads
<script dir>/roles/<name>.md; a role token with a / is a file path,
relative paths resolving against the config file's directory.
A leading * on a name marks the main agent, whose pane gets the big
left slot; without it, the first manager, else the first agent.
Full-line # comments and blank lines are skipped.

  *boss  claude               manager
  impl   codex --model gpt-5.6-sol  implementer
  fast   codex                -
  weird  claude               ./my-roles/chaos.md

Team resolution: CLI agent commands > -c file > ./peon-code.conf >
~/.config/peon-code/peon-code.conf > claude codex.
USAGE
}

die() {
  echo "peon-code: $*" >&2
  exit 1
}

# shellcheck source=lib/tmux.sh
source "$SCRIPT_DIR/lib/tmux.sh"
# shellcheck source=lib/input.sh
source "$SCRIPT_DIR/lib/input.sh"
# shellcheck source=lib/delivery.sh
source "$SCRIPT_DIR/lib/delivery.sh"
# shellcheck source=lib/session.sh
source "$SCRIPT_DIR/lib/session.sh"
# shellcheck source=lib/commands.sh
source "$SCRIPT_DIR/lib/commands.sh"
# shellcheck source=lib/mouse.sh
source "$SCRIPT_DIR/lib/mouse.sh"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=lib/resume.sh
source "$SCRIPT_DIR/lib/resume.sh"
# shellcheck source=lib/brief.sh
source "$SCRIPT_DIR/lib/brief.sh"
# shellcheck source=lib/watch.sh
source "$SCRIPT_DIR/lib/watch.sh"

START_ARGS=("$@")
CONF=""
CONF_GIVEN=0
while getopts ":c:h" opt; do
  case $opt in
    c) CONF=$OPTARG; CONF_GIVEN=1 ;;
    h) usage; exit 0 ;;
    :) die "option -$OPTARG needs a file" ;;
    *) usage >&2; die "unknown option -$OPTARG" ;;
  esac
done
shift $((OPTIND - 1))

RESUME=0
case "${1:-}" in
  resume) RESUME=1; shift ;;
  dismiss) shift; cmd_dismiss "$@"; exit 0 ;;
  detach) shift; cmd_detach "$@"; exit 0 ;;
  msg)  shift; cmd_msg "$@"; exit 0 ;;
  send) shift; cmd_send "$@"; exit 0 ;;
  key) shift; cmd_key "$@"; exit 0 ;;
  explain) shift; cmd_explain "$@"; exit 0 ;;
  rebrief) shift; cmd_rebrief "$@"; exit 0 ;;
  compact) shift; cmd_compact "$@"; exit 0 ;;
  clear) shift; cmd_clear "$@"; exit 0 ;;
  watch) shift; cmd_watch "$@"; exit 0 ;;
  list) [ $# -eq 1 ] || die "list takes no arguments"; cmd_list; exit 0 ;;
  uninstall)
    for command_name in peon-code peon-code-web; do
      LINK="${2:-$HOME/.local/bin}/$command_name"
      if [ -L "$LINK" ] && [ "$(readlink "$LINK")" = "$SCRIPT_DIR/$command_name.sh" ]; then
        continue
      elif [ -e "$LINK" ] || [ -L "$LINK" ]; then
        echo "not removing $LINK: it does not point at $SCRIPT_DIR/$command_name.sh" >&2
        exit 1
      fi
    done
    for command_name in peon-code peon-code-web; do
      LINK="${2:-$HOME/.local/bin}/$command_name"
      if [ -L "$LINK" ]; then
        rm "$LINK" && echo "removed: $LINK"
      else
        echo "nothing to remove: $LINK does not exist"
      fi
    done
    exit 0 ;;
esac

SESSION=$(session_name "${1:-}")  # default session name: current directory
[ $# -gt 0 ] && shift
load_team "$@"
N=${#NAMES[@]}

# A pull rewrites this file under a bash that reads it lazily, so restart on
# the new code before anything else runs.
if offer_update local; then
  exec "$script_path" ${START_ARGS[@]+"${START_ARGS[@]}"}
fi
if tmux has-session -t "=$SESSION" 2>/dev/null; then
  is_peon_session "$SESSION" || die "session $SESSION already exists and was not created by peon-code"
  goto_session "$SESSION"
fi

# shellcheck source=lib/launch.sh
source "$SCRIPT_DIR/lib/launch.sh"
