#!/usr/bin/env bash
set -euo pipefail
script_path=${BASH_SOURCE[0]}
while [ -L "$script_path" ]; do
  link_target=$(readlink "$script_path")
  case "$link_target" in
    /*) script_path=$link_target ;;
    *) script_path=$(dirname -- "$script_path")/$link_target ;;
  esac
done
SCRIPT_DIR=$(cd -- "$(dirname -- "$script_path")" && pwd)
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
update_mode=local
for arg in "$@"; do
  case "$arg" in
    -h|--help) update_mode=skip ;;
    --stdio) [ "$update_mode" = skip ] || update_mode=stdio ;;
  esac
done
if [ "$update_mode" = stdio ]; then
  if offer_update stdio; then exec "$script_path" "$@"; fi
elif [ "$update_mode" = local ]; then
  if [ -t 0 ]; then
    if offer_update; then exec "$script_path" "$@"; fi
  else
    if offer_update </dev/null; then exec "$script_path" "$@"; fi
  fi
fi
command -v python3 >/dev/null || { echo 'peon-code-web requires Python 3.10 or newer' >&2; exit 1; }
if ! python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))'; then
  echo "peon-code-web requires Python 3.10 or newer (found $(python3 --version))" >&2
  exit 1
fi
exec python3 "$SCRIPT_DIR/web/server.py" "$@"
