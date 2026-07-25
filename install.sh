#!/usr/bin/env bash
# Symlink peon-code.sh into a bin directory as `peon-code`.
# Usage: ./install.sh [bin-dir]   (default: ~/.local/bin)
# Remove with: peon-code uninstall [bin-dir]
set -euo pipefail

BIN_DIR=${1:-"$HOME/.local/bin"}
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

mkdir -p "$BIN_DIR"
ln -sf "$SCRIPT_DIR/peon-code.sh" "$BIN_DIR/peon-code"
echo "installed: $BIN_DIR/peon-code -> $SCRIPT_DIR/peon-code.sh"

# Seed the fallback config, used when a directory has no ./peon-code.conf.
FALLBACK_CONF="$HOME/.config/peon-code/peon-code.conf"
if [ ! -f "$FALLBACK_CONF" ]; then
  mkdir -p "$(dirname "$FALLBACK_CONF")"
  cp "$SCRIPT_DIR/peon-code.conf.example" "$FALLBACK_CONF"
  echo "created fallback config: $FALLBACK_CONF (edit it to set your team)"
fi

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "note: $BIN_DIR is not on your PATH; add it to use plain 'peon-code'" ;;
esac
