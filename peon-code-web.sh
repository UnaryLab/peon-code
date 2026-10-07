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
# shellcheck source=lib/deps.sh
source "$SCRIPT_DIR/lib/deps.sh"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
update_mode=local
remote=0
for arg in "$@"; do
  case "$arg" in
    --) break ;;
    --ssh|--ssh=*) remote=1 ;;
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
python_version_ok || exit 1
[ "$update_mode" = skip ] || [ "$remote" = 1 ] || tmux_version_ok || exit 1
exec python3 "$SCRIPT_DIR/web/server.py" "$@"
