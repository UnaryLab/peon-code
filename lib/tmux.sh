# shellcheck shell=bash

# Session name for a directory: the given name, else the current directory.
# tmux rewrites . and : in session names, so match what it stores.
session_name() {
  local s=${1:-${PWD##*/}}
  s=${s:-peon-code}  # PWD is /
  printf '%s\n' "${s//[.:]/_}"
}

# The @peon_name pane option carries the agent name: unlike the pane title,
# an app cannot overwrite it. Panes without it are not ours and are skipped,
# as are panes running a shell: pasted text there would run as commands.
# With a session argument, only that session's panes; teams share agent
# names, so an unscoped match would reach every team on the server.
list_agent_panes() {
  local id cmd name scope=(-a)
  [ $# -gt 0 ] && scope=(-s -t "=$1")
  tmux list-panes "${scope[@]}" -F '#{pane_id} #{pane_current_command} #{@peon_name}' 2>/dev/null |
    while read -r id cmd name; do
      [ -n "$name" ] || continue
      case $cmd in
        sh|bash|zsh|fish|dash|ksh) continue ;;
      esac
      echo "$id $name"
    done
}

# Paste stdin into a pane. Bracketed paste keeps a multi-line block in the
# input line instead of submitting it early; long lines sent with send-keys
# are cut at the tty line limit. Every control byte but tab and newline is
# dropped first: tmux does not escape a bracketed-paste terminator inside the
# text, so text carrying one would end the paste early and leave the rest of
# itself to the receiving app as live keystrokes.
paste_only() {
  local pane=$1 buffer="peon-code-$$-${1#%}"
  # Each step is checked here rather than left to errexit: a caller that runs
  # this on the left of || turns errexit off for the whole call.
  LC_ALL=C tr -d '\000-\010\013-\037\177' | tmux load-buffer -b "$buffer" - || return 1
  tmux paste-buffer -b "$buffer" -dpt "$pane" || return 1
  return 0
}

# Paste stdin into a pane, then press Enter once the pane shows the paste: its
# input box holds the pasted text, either as itself or as the CLI's paste
# placeholder, and it takes keys. The box is read again on each of 15 tries,
# 0.2s apart, so a box still redrawing or an autocomplete list the paste
# opened gets time to show the text. Only a box that reads back non-empty is
# matched, so a pane on a dialog or a menu, one drawing no prompt marker
# peon-code knows, and an empty paste all press no Enter.
# A pane in copy mode routes an Enter through the copy-mode key table, so the
# tries run out there rather than pressing one; the user leaves copy mode and
# submits the text.
# A failed paste returns 1 and presses no Enter, so a pane that took no text
# keeps whatever the user had typed in its box. A paste the box never showed
# returns 2, with the text left in the box for the user to submit.
paste_to_pane() {
  local pane=$1 text want box i
  text=$(cat)
  want=$(printf '%s' "$text" | plain_text)
  printf '%s' "$text" | paste_only "$pane" || return 1
  for ((i = 0; i < 15; i++)); do
    sleep 0.2
    box=$(pane_box_text "$pane") || box=""
    [ -n "$box" ] || continue
    [ "$box" = "$want" ] || box_is_paste_placeholder "$box" || continue
    pane_takes_keys "$pane" || continue
    tmux send-keys -t "$pane" Enter || return 2
    return 0
  done
  return 2
}

# Printable ASCII only, runs of blanks squeezed to one space, ends trimmed:
# the shape a captured box and a message are both reduced to before they are
# compared, so the box's wrapping and padding do not count as a difference.
plain_text() {
  local s
  # LC_ALL=C: a capture holds the box drawing of the pane, and tr in a UTF-8
  # locale rejects those bytes instead of dropping them.
  s=$(LC_ALL=C tr -cd '\11\12\40-\176' | LC_ALL=C tr -s '\11\12\40' '\40')
  s=${s# }
  s=${s% }
  printf '%s' "$s"
}

# A capture holding a menu: the marker is drawn on the menu's selected row
# with the cursor right after it, so the input box measures empty while the
# pane is waiting on an answer.
pane_has_menu() {
  case $1 in
    *"Enter to confirm"*|*"❯ "[0-9]"."*|*"› "[0-9]"."*) return 0 ;;
  esac
  return 1
}

# A pane in copy mode routes keys through the copy-mode key table, so a paste
# lands in the pane but the Enter after it never reaches the app.
pane_takes_keys() {
  [ "$(tmux display -pt "$1" '#{pane_in_mode}' 2>/dev/null || echo 1)" = 0 ]
}

# Drop the SGR and other CSI escape codes from a capture read with -e, one
# line in, one line out. With a first argument of 1, the text of every span
# drawn dim or in a gray foreground becomes spaces first: that is how a TUI
# draws hint text, which is not typed text. The prompt marker is kept even
# inside such a span, so a marker drawn in a hint style is still found.
strip_styles() {
  LC_ALL=C awk -v hint="$1" '
    # Prompt markers: claude draws U+276F, codex U+203A; both are 3 bytes.
    BEGIN { m = "\342\235\257"; m2 = "\342\200\272"; csi = "\033["; osc = "\033]"; st = "\033\\" }
    {
      line = drop_osc($0); out = ""; dim = 0; gray = 0
      while ((p = index(line, csi)) > 0) {
        out = out span(substr(line, 1, p - 1), dim || gray)
        line = substr(line, p + 2)
        i = 1
        while (i <= length(line) && substr(line, i, 1) ~ /[0-9;:<=>?]/) i++
        if (substr(line, i, 1) == "m") sgr(substr(line, 1, i - 1))
        line = substr(line, i + 1)
      }
      print out span(line, dim || gray)
    }
    # An OSC string carries no style, only a payload such as a hyperlink URL,
    # which is not text the pane shows. It ends at a BEL or a string
    # terminator; an unterminated one runs to the end of the line.
    function drop_osc(s,   r, p, b, e) {
      r = ""
      while ((p = index(s, osc)) > 0) {
        r = r substr(s, 1, p - 1)
        s = substr(s, p + 2)
        b = index(s, "\007"); e = index(s, st)
        if (b > 0 && (e == 0 || b < e)) s = substr(s, b + 1)
        else if (e > 0) s = substr(s, e + 2)
        else return r
      }
      return r s
    }
    function span(s, styled) { return (hint && styled) ? blank(s) : s }
    function markpos(s,   p, q) {
      p = index(s, m); q = index(s, m2)
      if (p == 0) return q
      if (q == 0 || p < q) return p
      return q
    }
    function blank(s,   r, p) {
      r = ""
      while ((p = markpos(s)) > 0) {
        r = r spaces(p - 1) substr(s, p, 3)
        s = substr(s, p + 3)
      }
      return r spaces(length(s))
    }
    function spaces(n,   r) { r = ""; while (n-- > 0) r = r " "; return r }
    # 0 and an empty parameter list reset every attribute; 22 clears dim; a
    # 256-color index from 232 to 249 is one of the darker grays, and a
    # truecolor foreground is gray when its three channels sit within 16 of
    # each other. 250 and above are near-white, which some themes use for
    # ordinary text.
    # Italic is not a hint style here: CLIs draw ordinary text in it too, and
    # blanking it would erase what the user typed. Add it once a CLI is known
    # to reserve italic for hints.
    function sgr(params,   n, j, a, c, r, g, b, hi, lo) {
      n = split(params, f, ";")
      if (n == 0) { dim = 0; gray = 0 }
      for (j = 1; j <= n; j++) {
        a = f[j] + 0
        if (a == 0) { dim = 0; gray = 0 }
        else if (a == 2) dim = 1
        else if (a == 22) dim = 0
        else if (a == 38 || a == 48 || a == 58) {
          if (f[j + 1] + 0 == 5) { c = f[j + 2] + 0; if (a == 38) gray = (c >= 232 && c <= 249); j += 2 }
          else if (f[j + 1] + 0 == 2) {
            if (a == 38) {
              r = f[j + 2] + 0; g = f[j + 3] + 0; b = f[j + 4] + 0
              hi = r; if (g > hi) hi = g; if (b > hi) hi = b
              lo = r; if (g < lo) lo = g; if (b < lo) lo = b
              gray = (hi - lo <= 16 && hi <= 249)
            }
            j += 4
          }
        }
        else if (a == 39) gray = 0
        else if (a == 90) gray = 1
        else if ((a >= 30 && a <= 37) || (a >= 91 && a <= 97)) gray = 0
      }
    }'
}

# What a pane's input box holds: everything from the prompt marker to the end
# of the cursor's row, with hint text left out. Text after the cursor counts
# too, so a box whose cursor was moved back to the start still measures busy.
# Empty output means an empty box. A pane sitting on a menu returns 1; a pane
# drawing no prompt marker at or above the cursor returns 2, which no wait can
# change. The menu check reads the capture with its hint text in place: a
# dialog draws its "Enter to confirm" footer dim.
# One column per glyph, so a box holding wide characters measures short;
# count widths here if agents start sending CJK or emoji.
# Dim and gray are the only hint styles modeled. A style the parser does not
# model can blank text the user typed, so a busy box measures empty and
# peon-code pastes over it; model that style in strip_styles if a TUI draws
# hints another way.
pane_box_text() {
  local pane=$1 cy cap box
  cy=$(tmux display -pt "$pane" '#{cursor_y}' 2>/dev/null) || return 1
  cap=$(tmux capture-pane -ept "$pane" 2>/dev/null) || return 1
  if pane_has_menu "$(printf '%s\n' "$cap" | strip_styles 0)"; then
    return 1
  fi
  box=$(printf '%s\n' "$cap" | strip_styles 1 | LC_ALL=C awk -v cy="$cy" '
    # Prompt markers: claude draws U+276F, codex U+203A; both are 3 bytes.
    BEGIN { m = "\342\235\257"; m2 = "\342\200\272" }
    function markpos(s,   p, q) {
      p = index(s, m); q = index(s, m2)
      if (p == 0) return q
      if (q == 0 || p < q) return p
      return q
    }
    { rows[NR] = $0; if (NR <= cy + 1 && markpos($0) > 0) mr = NR }
    END {
      if (!mr) exit 2
      for (r = mr; r <= cy + 1; r++) {
        s = rows[r]
        if (r == mr) s = substr(s, markpos(s) + 3)
        out = out " " s
      }
      print out
    }') || return 2
  printf '%s' "$box" | plain_text
}

# Wait until a pane's shell has started: it reports a shell, or has drawn
# something. Bounded, so a pane that never reports still lets the run finish.
wait_shell_ready() {
  local pane=$1 i cur out
  for ((i = 0; i < 50; i++)); do
    cur=$(tmux display -pt "$pane" '#{pane_current_command}' 2>/dev/null) || cur=""
    case $cur in
      sh|bash|zsh|fish|dash|ksh) return 0 ;;
    esac
    out=$(tmux capture-pane -pt "$pane" 2>/dev/null) || out=""
    [ -n "${out//[[:space:]]/}" ] && return 0
    sleep 0.2
  done
}

# Wait until the agent CLI has replaced the shell in a pane.
wait_agent_ready() {
  local pane=$1 i cur
  for ((i = 0; i < 100; i++)); do
    cur=$(tmux display -pt "$pane" '#{pane_current_command}' 2>/dev/null) || cur=""
    case $cur in
      sh|bash|zsh|fish|dash|ksh|"") sleep 0.2 ;;
      *) return 0 ;;
    esac
  done
  return 1
}

# A resumed claude pane can open on a picker asking how to resume a large or
# old session; its default row is "Resume from summary (recommended)". Enter
# accepts that default, so the pane moves on instead of sitting on the dialog
# until the settle wait gives up. A pane that reaches the input line first
# never showed the picker, so the wait ends there. Always returns 0: a pane
# still drawing after the cap is left for wait_pane_settled to judge.
answer_resume_picker() {
  local pane=$1 i cur
  for ((i = 0; i < 50; i++)); do
    cur=$(tmux capture-pane -pt "$pane" 2>/dev/null) || cur=""
    if [[ $cur == *"Resume from summary"* ]]; then
      tmux send-keys -t "$pane" Enter
      return 0
    fi
    # Input line drawn and no menu on screen: the pane never showed a picker.
    if ! pane_has_menu "$cur" && [[ $cur == *❯* || $cur == *›* ]]; then
      return 0
    fi
    sleep 0.3
  done
  return 0
}

# Wait until the claude prompt line is drawn and the pane has stopped
# changing: a capture holds a line starting with the prompt marker and
# matches the capture 0.3s before. A menu such as the folder-trust dialog
# draws the same marker on its selected row, so a capture holding a menu
# is never settled: the wait continues until the user answers it.
# The tries cap, 30s by default, ends the wait when a spinner keeps redrawing,
# the prompt never shows, or the dialog goes unanswered; the caller then
# skips the paste rather than typing into whatever is on screen.
wait_pane_settled() {
  local pane=$1 tries=${2:-100} i prev="" cur
  for ((i = 0; i < tries; i++)); do
    cur=$(tmux capture-pane -pt "$pane" 2>/dev/null) || cur=""
    if pane_has_menu "$cur"; then
      cur=""  # a menu, not the input line
    fi
    if [[ $cur == *❯* || $cur == *›* ]] && [ "$cur" = "$prev" ]; then
      return 0
    fi
    prev=$cur
    sleep 0.3
  done
  return 1
}

is_peon_session() {
  local session=$1
  [ "$(tmux show-options -qv -t "$session" @peon_code 2>/dev/null || true)" = 1 ]
}

# A CLI can draw a multi-line paste as one placeholder row instead of its
# text: claude draws "[Pasted text #2 +15 lines]", codex "[Pasted Content
# 1234 chars]", copilot "[Paste #2 - 15 lines]", grok "[Pasted: 5 lines]". The
# box is checked empty right before the paste, so a box holding exactly one
# placeholder holds the pasted message. Add other CLIs' forms here as they show up.
box_is_paste_placeholder() {
  local claude='^\[Pasted text #[0-9]+( \+[0-9]+ lines)?\]$'
  local codex='^\[Pasted Content [0-9]+ chars\]$'
  local copilot='^\[Paste #[0-9]+( - [0-9]+ lines)?\]$'
  local grok='^\[Pasted: [0-9]+ lines?\]$'
  [[ $1 =~ $claude ]] || [[ $1 =~ $codex ]] || [[ $1 =~ $copilot ]] || [[ $1 =~ $grok ]]
}
