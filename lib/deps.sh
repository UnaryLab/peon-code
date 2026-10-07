# shellcheck shell=bash

tmux_version_ok() {
  local found pattern='^[^0-9]*([0-9]+)\.([0-9]+)'
  if ! command -v tmux >/dev/null 2>&1; then
    echo 'peon-code: tmux 3.2 or newer is required (found not installed)' >&2
    return 1
  fi
  found=$(tmux -V 2>/dev/null) || found=""
  if [[ $found =~ $pattern ]] &&
    { [ "${BASH_REMATCH[1]}" -gt 3 ] || { [ "${BASH_REMATCH[1]}" -eq 3 ] && [ "${BASH_REMATCH[2]}" -ge 2 ]; }; }; then
    return 0
  fi
  found=${found//$'\n'/ }
  echo "peon-code: tmux 3.2 or newer is required (found ${found:-unknown})" >&2
  return 1
}

python_version_ok() {
  command -v python3 >/dev/null 2>&1 || {
    echo 'peon-code-web requires Python 3.10 or newer' >&2
    return 1
  }
  if ! python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))'; then
    echo "peon-code-web requires Python 3.10 or newer (found $(python3 --version))" >&2
    return 1
  fi
}

package_manager() {
  local candidate
  for candidate in brew apt-get dnf pacman; do
    if command -v "$candidate" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

offer_tmux_install() {
  command -v tmux >/dev/null 2>&1 && return 0
  local manager reply=n install_command
  manager=$(package_manager) || {
    echo 'install tmux 3.2+ with your package manager' >&2
    return 1
  }
  case $manager in
    brew) install_command=(brew install tmux) ;;
    apt-get) install_command=(sudo apt-get install -y tmux) ;;
    dnf) install_command=(sudo dnf install -y tmux) ;;
    pacman) install_command=(sudo pacman -S --noconfirm tmux) ;;
  esac
  if [ "${PEON_INSTALL_ASSUME_YES:-0}" = 1 ]; then
    reply=y
  elif [ -t 0 ]; then
    printf 'tmux is not installed; install it with %s? [y/N]' "$manager"
    read -r reply || reply=n
  fi
  case $reply in
    [yY]|[yY][eE][sS])
      if "${install_command[@]}" && command -v tmux >/dev/null 2>&1; then return 0; fi ;;
  esac
  echo "${install_command[*]}" >&2
  return 1
}
