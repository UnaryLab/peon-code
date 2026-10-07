#!/usr/bin/env bash
# Install the peon-code and peon-code-web command symlinks into a bin directory.
# Usage: ./install.sh [bin-dir]   (default: ~/.local/bin)
# Remove with: peon-code uninstall [bin-dir]
set -euo pipefail

BIN_DIR=${1:-"$HOME/.local/bin"}
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
mkdir -p "$BIN_DIR"
# Check both commands before installing either one.
for command_name in peon-code peon-code-web; do
  LINK="$BIN_DIR/$command_name"
  source_script="$SCRIPT_DIR/$command_name.sh"
  if [ -L "$LINK" ]; then
    [ "$(readlink "$LINK")" = "$source_script" ] ||
      { echo "not replacing $LINK: it points to $(readlink "$LINK")" >&2; exit 1; }
  elif [ -e "$LINK" ]; then
    echo "not replacing $LINK: it already exists" >&2
    exit 1
  fi
done
for command_name in peon-code peon-code-web; do
  LINK="$BIN_DIR/$command_name"
  [ -L "$LINK" ] || ln -s "$SCRIPT_DIR/$command_name.sh" "$LINK"
  echo "installed: $LINK -> $SCRIPT_DIR/$command_name.sh"
done

# Seed the fallback config, used when a directory has no ./peon-code.conf.
FALLBACK_CONF="$HOME/.config/peon-code/peon-code.conf"
if [ ! -f "$FALLBACK_CONF" ]; then
  mkdir -p "$(dirname "$FALLBACK_CONF")"
  cp "$SCRIPT_DIR/peon-code.conf.example" "$FALLBACK_CONF"
  echo "created fallback config: $FALLBACK_CONF (edit it to set your team)"
fi

# Install the tmux config, prompting before overwriting an existing one.
TMUX_CONF="$HOME/.tmux.conf"
if [ -e "$TMUX_CONF" ]; then
  if [ -t 0 ]; then
    printf '%s already exists; overwrite it? [y/N] ' "$TMUX_CONF"
    read -r reply
  else
    reply=n
  fi
  case "$reply" in
    [yY]|[yY][eE][sS])
      cp "$SCRIPT_DIR/tmux.conf" "$TMUX_CONF"
      echo "overwrote: $TMUX_CONF" ;;
    *) echo "kept your existing $TMUX_CONF (run 'cp $SCRIPT_DIR/tmux.conf $TMUX_CONF' to overwrite)" ;;
  esac
else
  cp "$SCRIPT_DIR/tmux.conf" "$TMUX_CONF"
  echo "installed: $TMUX_CONF"
fi

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "note: $BIN_DIR is not on your PATH; add it to use plain 'peon-code'" ;;
esac
