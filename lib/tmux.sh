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

# Paste stdin into a pane, then press Enter as a separate call. A failed paste
# returns 1 and presses no Enter, so a pane that took no text keeps whatever
# the user had typed in its box.
paste_to_pane() {
  paste_only "$1" || return 1
  sleep 1
  tmux send-keys -t "$1" Enter
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

cmd_dismiss() {
  local session
  session=$(session_name "${1:-}")
  if ! tmux has-session -t "=$session" 2>/dev/null; then
    echo "peon-code: no session $session"
    exit 0
  fi
  is_peon_session "$session" || die "session $session was not created by peon-code"
  echo "peon-code: killing session $session"
  tmux kill-session -t "=$session"
}

cmd_msg() {
  local target=${1:-} text=${2:-} session panes id name
  [ -n "$target" ] && [ -n "$text" ] || die "usage: peon-code.sh msg <name|all> 'text' [<session>]"
  session=$(session_name "${3:-}")
  tmux has-session -t "=$session" 2>/dev/null || die "no session $session"
  is_peon_session "$session" || die "session $session was not created by peon-code"
  panes=$(list_agent_panes "$session") || true
  [ -n "$panes" ] || die "no agent panes in session $session"
  local ids=()
  while read -r id name; do
    if [ "$target" = all ] || [ "$target" = "$name" ]; then
      ids+=("$id")
    fi
  done <<<"$panes"
  if [ ${#ids[@]} -eq 0 ]; then
    echo "peon-code: no pane named $target in session $session. Agent panes found:" >&2
    while read -r id name; do
      echo "  $name $id" >&2
    done <<<"$panes"
    exit 1
  fi
  for id in "${ids[@]}"; do
    printf '%s' "[from user] $text" | paste_only "$id"
  done
  sleep 1
  for id in "${ids[@]}"; do
    tmux send-keys -t "$id" Enter
  done
  echo "peon-code: sent to ${#ids[@]} pane(s) in session $session"
}

# Send /compact to agent panes, so each CLI compacts its own context, then
# paste each compacted pane's brief back once its compaction has finished. The
# slash command is pasted on its own: any text before it stops the CLI from
# reading it as a command. A pane whose input box cannot be read or holds
# typed text is skipped, and the rest still get the command. Enter follows
# only once the box holds the command alone, so a dialog or an autocomplete
# list that opened after the paste does not take the Enter as its answer.
cmd_compact() {
  local target=${1:-all} session panes id name pair box i submitted sent=0
  local pairs=() compacted=()
  session=$(session_name "${2:-}")
  tmux has-session -t "=$session" 2>/dev/null || die "no session $session"
  is_peon_session "$session" || die "session $session was not created by peon-code"
  panes=$(list_agent_panes "$session") || true
  [ -n "$panes" ] || die "no agent panes in session $session"
  while read -r id name; do
    if [ "$target" = all ] || [ "$target" = "$name" ]; then
      pairs+=("$id $name")
    fi
  done <<<"$panes"
  if [ ${#pairs[@]} -eq 0 ]; then
    echo "peon-code: no pane named $target in session $session. Agent panes found:" >&2
    while read -r id name; do
      echo "  $name $id" >&2
    done <<<"$panes"
    exit 1
  fi
  for pair in "${pairs[@]}"; do
    id=${pair%% *}
    name=${pair#* }
    if ! pane_takes_keys "$id"; then
      echo "peon-code: skipped $id: it is in copy mode" >&2
      continue
    fi
    box=$(pane_box_text "$id") || case $? in
      2) echo "peon-code: skipped $id: it draws no prompt marker peon-code knows" >&2; continue ;;
      *) echo "peon-code: skipped $id: it is on a dialog or a menu" >&2; continue ;;
    esac
    if [ -n "$box" ]; then
      echo "peon-code: skipped $id: its input box holds typed text" >&2
      continue
    fi
    printf '%s' /compact | paste_only "$id"
    submitted=0
    for ((i = 0; i < 10; i++)); do
      sleep 0.2
      box=$(pane_box_text "$id") || box=""
      [ "$box" = /compact ] || continue
      pane_takes_keys "$id" || break
      tmux send-keys -t "$id" Enter
      submitted=1
      break
    done
    if [ "$submitted" -eq 1 ]; then
      sent=$((sent + 1))
      compacted+=("$pair")
    else
      echo "peon-code: no Enter sent to $id: it holds something other than /compact, which is in its box for the user to submit" >&2
    fi
  done
  [ "$sent" -gt 0 ] || die "no pane took /compact in session $session"
  echo "peon-code: sent /compact to $sent pane(s) in session $session"
  # Compaction runs for as long as the context takes, well past the settle
  # wait's default ceiling, so the wait is given 120s here. A pane still
  # drawing after that keeps its brief unsent rather than taking a paste
  # into whatever is on screen.
  for pair in ${compacted[@]+"${compacted[@]}"}; do
    id=${pair%% *}
    name=${pair#* }
    if ! wait_pane_settled "$id" 400; then
      echo "peon-code: no brief sent to $name $id: it is still busy after compacting" >&2
      continue
    fi
    rebrief_pane "$id" "$name" || case $? in
      2) echo "peon-code: no brief sent to $name $id: tmux refused the paste" >&2 ;;
      3) echo "peon-code: no brief sent to $name $id: its input box holds typed text, or it is on a dialog or a menu" >&2 ;;
    esac
  done
}

# A CLI can draw a multi-line paste as one placeholder row instead of its
# text: claude draws "[Pasted text #2 +15 lines]", codex "[Pasted Content
# 1234 chars]", copilot "[Paste #2 - 15 lines]". The box is checked empty
# right before the paste, so a box holding exactly one placeholder holds the
# pasted message. Add other CLIs' placeholder forms here as they show up.
box_is_paste_placeholder() {
  local claude='^\[Pasted text #[0-9]+( \+[0-9]+ lines)?\]$'
  local codex='^\[Pasted Content [0-9]+ chars\]$'
  local copilot='^\[Paste #[0-9]+( - [0-9]+ lines)?\]$'
  [[ $1 =~ $claude ]] || [[ $1 =~ $codex ]] || [[ $1 =~ $copilot ]]
}

# Send one agent's message to another agent's pane. A message of - is read
# from stdin, which keeps quotes in it off the sender's command line. One run
# makes the box check and the paste back to back, and Enter follows only once
# the box holds the message, either as its text or as the CLI's paste
# placeholder; a box holding anything else keeps both the message and
# whatever the user typed.
cmd_send() {
  local pane=${1:-} text=${2:-} want box i
  [ -n "$pane" ] && [ -n "$text" ] || die "usage: peon-code.sh send <pane-id> 'text'|-"
  if [ "$text" = - ]; then
    text=$(cat)
    [ -n "$text" ] || die "no message on stdin"
  fi
  case $(tmux display -pt "$pane" '#{pane_current_command}' 2>/dev/null || true) in
    "") die "no pane $pane" ;;
    sh|bash|zsh|fish|dash|ksh) die "pane $pane is back at a shell; its agent is gone" ;;
  esac
  # The pane option is set on agent panes at launch: a paste is refused
  # anywhere else, rather than reaching any pane on the tmux server.
  [ -n "$(tmux show-options -pqv -t "$pane" @peon_name 2>/dev/null || true)" ] ||
    die "pane $pane is not a peon-code agent pane"
  pane_takes_keys "$pane" || die "pane $pane is in copy mode, retry later"
  box=$(pane_box_text "$pane") || case $? in
    2) die "pane $pane draws no prompt marker peon-code knows; message it by hand" ;;
    *) die "pane $pane is on a dialog or a menu, retry later" ;;
  esac
  [ -z "$box" ] || die "target box busy, retry later"
  want=$(printf '%s' "$text" | plain_text)
  printf '%s' "$text" | paste_only "$pane"
  for ((i = 0; i < 10; i++)); do
    sleep 0.2
    box=$(pane_box_text "$pane") || box=""
    if [ "$box" = "$want" ] || box_is_paste_placeholder "$box"; then
      pane_takes_keys "$pane" ||
        die "no Enter sent: pane $pane went into copy mode, and the message is in its box for the user to submit"
      tmux send-keys -t "$pane" Enter
      echo "peon-code: sent to $pane"
      return 0
    fi
  done
  die "no Enter sent: pane $pane holds something other than the message, which is still in its box for the user to sort out"
}

# Paste one pane's launch brief again. The brief file path is stored on each
# pane as the @peon_brief option at launch; a pane without one is left alone
# and reported, which returns 1, as does a pane drawing no prompt marker. A
# paste tmux refused returns 2. A pane whose input box holds typed text, or
# that sits on a dialog or a menu, takes nothing and returns 3, so the box
# keeps what the user typed and no Enter answers the dialog.
rebrief_pane() {
  local id=$1 name=$2 brief box
  brief=$(tmux show-options -pqv -t "$id" @peon_brief 2>/dev/null) || brief=""
  if [ -z "$brief" ] || [ ! -f "$brief" ]; then
    echo "peon-code: no stored brief for $name $id: pane from an older launch, or its brief file is gone" >&2
    return 1
  fi
  box=$(pane_box_text "$id") || case $? in
    2) echo "peon-code: no brief sent to $name $id: it draws no prompt marker peon-code knows" >&2; return 1 ;;
    *) return 3 ;;
  esac
  [ -z "$box" ] || return 3
  paste_to_pane "$id" <"$brief" || return 2
  return 0
}

# Paste the launch brief again into every named pane, so an agent that
# compacted its conversation gets its standing instructions back.
cmd_rebrief() {
  local target=${1:-} session panes id name found=0 sent=0 refused=0
  [ -n "$target" ] || die "usage: peon-code.sh rebrief <name|all> [<session>]"
  session=$(session_name "${2:-}")
  tmux has-session -t "=$session" 2>/dev/null || die "no session $session"
  is_peon_session "$session" || die "session $session was not created by peon-code"
  panes=$(list_agent_panes "$session") || true
  [ -n "$panes" ] || die "no agent panes in session $session"
  while read -r id name; do
    [ "$target" = all ] || [ "$target" = "$name" ] || continue
    found=1
    rebrief_pane "$id" "$name" || case $? in
      2) echo "peon-code: no brief sent to $name $id: tmux refused the paste" >&2
         refused=$((refused + 1)); continue ;;
      3) echo "peon-code: no brief sent to $name $id: its input box holds typed text, or it is on a dialog or a menu" >&2
         continue ;;
      *) continue ;;
    esac
    sent=$((sent + 1))
  done <<<"$panes"
  [ "$found" -eq 1 ] || die "no pane named $target in session $session"
  [ "$sent" -gt 0 ] || die "no brief sent in session $session"
  echo "peon-code: rebriefed $sent pane(s) in session $session"
  [ "$refused" -eq 0 ] || die "$refused pane(s) took no brief in session $session"
}

# Every agent pane on the server, so a session can be found without
# remembering the directory it was launched from. A pane back at a shell
# is reported as gone: its agent exited.
cmd_list() {
  local out rows="" session id cmd name
  # Tab-separated: a session name can hold spaces.
  out=$(tmux list-panes -a -F $'#{session_name}\t#{pane_id}\t#{pane_current_command}\t#{@peon_name}' 2>/dev/null) || out=""
  while IFS=$'\t' read -r session id cmd name; do
    [ -n "$name" ] || continue
    # An agent CLI renames its process, so the name itself says little;
    # what the user needs is whether the pane is back at a shell.
    case $cmd in
      sh|bash|zsh|fish|dash|ksh) cmd="gone ($cmd)" ;;
      *) cmd=running ;;
    esac
    rows+=$(printf '%-16s %-10s %-6s %s' "$session" "$name" "$id" "$cmd")$'\n'
  done <<<"$out"
  [ -n "$rows" ] || { echo "peon-code: no agent panes"; return; }
  printf '%-16s %-10s %-6s %s\n' SESSION AGENT PANE STATUS
  printf '%s' "$rows" | sort
}

goto_session() {
  local session=$1
  # No TTY means a headless caller: build the session, print how to reach it.
  if [ ! -t 0 ]; then
    echo "peon-code: session $session is ready. Attach with: tmux attach -t $session"
    exit 0
  fi
  if [ -n "${TMUX:-}" ]; then
    exec tmux switch-client -t "=$session"
  fi
  exec tmux attach -t "=$session"
}

create_agent_session() {
  local session=$1 count=$2 main=$3 i pane_id
  # First agent is the new-session window; the rest are split off it.
  # Retile after each split so large teams do not hit "pane too small".
  tmux new-session -d -s "$session" -n agents -c "$PWD"
  tmux set-option -t "$session" @peon_code 1
  # Session-scoped, so the terminal tab caption is set only here.
  tmux set -t "$session" set-titles on
  tmux set -t "$session" set-titles-string '#S : #{b:pane_current_path}'
  for ((i = 1; i < count; i++)); do
    if ! tmux split-window -t "$session":agents -c "$PWD"; then
      tmux kill-session -t "=$session"
      die "could not make pane $((i + 1)) of $count; killed session $session"
    fi
    tmux select-layout -t "$session":agents tiled >/dev/null || true
  done

  # Stable pane IDs survive pane moves and layout changes, unlike indices.
  PANE_IDS=()
  while read -r pane_id; do
    PANE_IDS+=("$pane_id")
  done < <(tmux list-panes -t "$session":agents -F '#{pane_id}')

  # A failed split leaves a half-built session; drop the one this run made.
  if [ ${#PANE_IDS[@]} -ne "$count" ]; then
    tmux kill-session -t "=$session"
    die "made ${#PANE_IDS[@]} panes for $count agents; killed session $session"
  fi

  # The main agent's pane takes the whole left side, the others stack to its
  # right. Swapped into the first position first, since main-vertical makes
  # that pane the main one. PANE_IDS is left alone: a pane id follows its
  # pane. A layout call tmux rejects leaves the tiled arrangement in place.
  [ "$main" -eq 0 ] || tmux swap-pane -d -s "${PANE_IDS[$main]}" -t "${PANE_IDS[0]}"
  tmux set-option -w -t "$session":agents main-pane-width 60% || true
  tmux select-layout -t "$session":agents main-vertical >/dev/null || true
}
