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

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "note: $BIN_DIR is not on your PATH; add it to use plain 'peon-code'" ;;
esac
