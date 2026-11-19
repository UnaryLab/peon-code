# shellcheck shell=bash

# The board file's opening lines: the editing rules and the table header.
# The seeded file and the brief's recreate instruction both use this text,
# so agents relearn the rules every time they read the board.
BOARD_HEADER='# task board

One row per task, edited in place: edit only the cells your type owns: a worker its own rows, the reviewer the status cell of a row it reviewed, the manager a done repair, the deletion, and the removal of a row it re-splits or reassigns after a blocked message; never rewrite the rest of the file. id is T1, T2, ... assigned by the row creator and never reused, even after the row is deleted. status holds exactly one of: in progress, done, reviewed pass, reviewed fail; a status change overwrites the cell, never appends to it. Keep a row to one line with a short task name, no progress notes; findings and reasons travel by message, never on the board.

| id | who | task | files | status |
|----|-----|------|-------|--------|'
# This substitution depends on the literal T1, T2 text in BOARD_HEADER.
PLAN_HEADER=${BOARD_HEADER/T1, T2/D1, D2}
PLAN_HEADER=${PLAN_HEADER/ status holds/ Only the director edits this file; the manager named in who reports its row by message. status holds}

board_for() {
  local i=$1 team=${TEAMS[$1]:-}
  if [ "${NAMES[$i]}" = director ]; then
    printf '.peon-code-plan.md\n'
  elif [ "$team" != "${TEAM_NAMES[0]:-${SESSION:-}}" ]; then
    printf '.peon-code-task.%s.md\n' "$team"
  else
    printf '%s\n' "$TASK_BOARD"
  fi
}

board_header_for() {
  local i=$1 HEADER=$BOARD_HEADER main=${MAIN:-${MAIN_INDEX:-0}}
  [ "$main" -ge 0 ] || main=0
  if [ "${NAMES[$i]}" = director ]; then
    HEADER=$PLAN_HEADER
  elif [ "${NAMES[$main]}" = director ]; then
    HEADER=${HEADER/ status holds/ Every task cell starts with the plan row id it serves, like D2: rename parser. status holds}
  fi
  printf '%s\n' "$HEADER"
}

seed_board() {
  local i=$1 board
  board=$(board_for "$i")
  [ -f "$board" ] || board_header_for "$i" >"$board"
}

# Build one agent's launch brief, printed to stdout for the caller to
# capture. Reads NAMES, CMDS, ROLES, ROSTER, MAIN, SESSION, N, SCRIPT_DIR,
# TEAMS, TEAM_NAMES, TASK_BOARD, GIT_DENY_PROSE, and PANE_IDS from the caller's scope.
build_brief() {
  local i=$1 WHO MSG_FROM ROLE_SECTION RULE1 RULE2 RULE7 MSG_WHEN CLAIM_PARA RULE8 RULE10_TAIL RULE10_CLAIM BOARD HEADER TEAM_RULE="" REPORT_TO="the user" TYPE=""
  BOARD=$(board_for "$i")
  HEADER=$(board_header_for "$i")
  if [ "${NAMES[$MAIN]}" = director ] && [ "$i" -ne "$MAIN" ]; then
    TEAM_RULE="You are in team ${TEAMS[$i]}. Message only panes of your own team and the director; the director handles git and talks to the user."
  fi
  WHO="${NAMES[$i]} (${CMDS[$i]})"
  [ "${NAMES[$i]}" = "${CMDS[$i]}" ] && WHO="${NAMES[$i]}"
  # Message prefix: CLI binary plus agent name; just the binary when the
  # name is the command itself (a roleless CLI team).
  MSG_FROM="${CMDS[$i]%% *} ${NAMES[$i]}"
  [ "${NAMES[$i]}" = "${CMDS[$i]}" ] && MSG_FROM="${CMDS[$i]%% *}"
  # A role pane gets its role body plus the team protocol once, sliced to
  # its own duties section.
  ROLE_SECTION=""
  if [ -n "${ROLES[$i]}" ]; then
    TYPE=$(role_field "${ROLES[$i]}" type)
    ROLE_SECTION="Your role: $(role_label "${ROLES[$i]}"), type $TYPE: $(role_field "${ROLES[$i]}" description)
$(role_body "${ROLES[$i]}")

Team protocol, with the duties section for your type:
$(protocol_for "$TYPE")
"
  fi
  if [ -n "$TEAM_RULE" ]; then
    REPORT_TO="your team manager"
    case $TYPE in manager|'') REPORT_TO="the director" ;; esac
  fi
  RULE1="1. Task intake: the user assigns work by typing into the ${NAMES[$MAIN]} pane (${PANE_IDS[$MAIN]}). That agent splits the work onto the task board and assigns it; every other agent waits for a board entry or a message instead of inventing work at launch. The agent that split the work posts the final summary to the user."
  if [ "${NAMES[$MAIN]}" = director ]; then
    RULE1="1. Task intake: the user assigns work by typing into the director pane (${PANE_IDS[$MAIN]}). That agent splits the work onto the plan board and dispatches each part to a team manager, who splits it onto your team board and assigns it. The director posts the final summary to the user."
  fi
  RULE10_CLAIM=" Claim every open task assigned to you whose files do not overlap what you or any other agent already claimed, and if your CLI can spawn subagents or background tasks, run them at the same time; if it cannot, switch between them rather than finishing one before you start the next."
  case $TYPE in manager|director) RULE10_CLAIM="" ;; esac
  # The board and message rules a roleless pane needs; a role pane already
  # carries them in the protocol, so these stay empty for it.
  MSG_WHEN=" Message another agent only when: (1) you finish a task; (2) you are blocked or detect a conflicting edit. The board row is the claim, so starting a task sends no message. After the sender prefix, an alert is one line naming the row id, like T3 done or T3 blocked: <why in a few words>; reviewer verdicts are also sent by message (a pass as one line, a fail as a short findings list), because a board edit alone wakes nobody. Do not message for routine progress or individual file saves."
  CLAIM_PARA="Record your claim on the board before you start (a new id, your name, the task, the files you will touch, status in progress) and read the board first: do not touch files someone else already listed. Messages are alerts; the board is the record that lasts. Batch edits that fall at the same step boundary, like several claims at launch or the verdicts of one review pass, into one edit, but never delay a status change to collect a batch: a done row gets its edit now."
  RULE8="8. Stale board rows: after a clear, compact, or rebrief, re-read the board and trust a row only if its status matches reality. If a row says in progress but the deliverable already exists, confirm with the owner before redoing the work."
  RULE10_TAIL=" Tasks touching the same files still run one at a time, and every claimed row still gets its own done edit and its own completion message. A message that arrives while you are working is new work, not an interruption: at your next step boundary, re-read the board and start any new row that does not overlap your current claims, rather than waiting until your current task is done."
  if [ -n "${ROLES[$i]}" ]; then
    MSG_WHEN=""
    CLAIM_PARA="The board and message rules are in the team protocol above."
    RULE8="8. Stale board rows: see the team protocol above."
    RULE10_TAIL=""
  fi
  # Rule 2 gets a hard git prohibition for every agent that is not main.
  # claude panes have the same prohibition enforced by the launch-time deny
  # settings file; codex and the other CLIs have no launch-time permission
  # file, so for them this sentence is the only guard, and it does not reach
  # subagents they spawn.
  RULE2="2. Git discipline: never run git add -A and never run destructive git commands unless the user asks. Stage only the files you claimed. Only one agent touches git at a time. Commits happen only when the user asks for one, and only in the ${NAMES[$MAIN]} pane (${PANE_IDS[$MAIN]}): any other agent asked to commit messages that pane instead of committing."
  if [ "${NAMES[$i]}" = director ]; then
    RULE2=${RULE2/Stage only the files you claimed./Stage only the files listed in the plan rows you have checked.}
  fi
  if [ "$i" -ne "$MAIN" ]; then
    RULE2="$RULE2 Hard prohibition for this pane: never run git $GIT_DENY_PROSE; only the main agent commits and touches branches."
  fi
  # Rule 7: a role pane points at the protocol it already carries. A roleless
  # pane gets the worker sentence, plus the manager verification sentence for
  # the main pane only.
  RULE7="7. Task completion: set your board row to done before you send the completion message. A task is not done until its row says done; a message never substitutes for the row edit. Send the completion message to the manager and, when the team has a reviewer, to the reviewer as well: an agent acts only when a message reaches its pane, a board edit alone wakes nobody."
  if [ -n "${ROLES[$i]}" ]; then
    RULE7="7. Task completion and messaging: follow the team protocol above for your type; the board row edit always precedes the message, because an agent acts only when a message reaches its pane, a board edit alone wakes nobody."
  elif [ "$i" -eq "$MAIN" ]; then
    RULE7="$RULE7 On receiving a completion message, verify the sender's board row is done and set it to done yourself if it is not, before acknowledging the work or dispatching new work; if the row already reads reviewed pass or reviewed fail, leave that status as the reviewer wrote it rather than setting it to done, and when it still reads reviewed fail, message the author to finish the rework. Once the work is verified, delete the row from the board, but only after the reviewer records a verdict on it if the team has one; the board lists only open work, and the deletion is the acknowledgment, so message a worker only to assign, reassign, request rework, or unblock. When you dispatch, send each agent one message listing all its row ids rather than one message per row, never delaying a ready dispatch to collect a batch."
  fi
  cat <<EOF
You are $WHO, agent ${NAMES[$i]} of peon-code session $SESSION, in pane $i of $N (this pane is ${PANE_IDS[$i]}), one of $N AI coding agents collaborating side-by-side in tmux. The panes are:
$ROSTER
$ROLE_SECTION
${TEAM_RULE:+$TEAM_RULE
}To read another agent's latest output, run: tmux capture-pane -pt <other-pane-id> -S -100. To send another agent a message, run this, with the message on the lines between the markers:
$SCRIPT_DIR/peon-code.sh send <other-pane-id> - <<'PEON'
your message
PEON
The message is read from stdin, so quotes and apostrophes in it stay out of your shell. It pastes the message and presses Enter only once the target's input box holds it, and it exits non-zero without pasting when that box already holds typed text. Start every message you send with [from $MSG_FROM ${PANE_IDS[$i]}] so receivers know who sent it and can tell messages apart from scraped output.$MSG_WHEN Check the other panes at task start and task end only; between those, read the task board instead.

The task board is $BOARD in the working directory. Its header states the row format, the id rule, and the status rules; keep that header intact, and if the file is missing create it with exactly this content:

$HEADER

$CLAIM_PARA

Rules:
$RULE1
$RULE2
3. Held sends: when send gives up on a blocked target (in copy mode, on a dialog or a menu, or holding typed text in its box), do something else and retry later. When send says no Enter sent, the message is already in the box: do not resend; tell $REPORT_TO. Never paste into that pane by hand.
4. Dead-pane guard: when send refuses a pane that is back at a shell, or a pane you read shows a shell prompt instead of an agent, that agent is gone. When send refuses a pane as missing, not an agent pane, or drawing no prompt marker it knows, check the id against the roster. In every case tell $REPORT_TO.
5. No idle deadlocks: if you are blocked, message once, work on something else, then re-check once. After that, proceed on your best judgment or tell $REPORT_TO.
6. Rate limits: if you hit a usage limit, note it and the reset time on the task board so the others can reassign the work.
$RULE7
$RULE8
9. Use your tools: when your CLI offers a built-in skill, command, or subagent that fits the task, prefer it over doing the work by hand.
10. Parallel work: independent tasks run at the same time, not one after another.$RULE10_CLAIM Any subagent you spawn gets git read-only in its prompt: never checkout, restore, reset, clean, stash, or any command that discards working-tree changes.$RULE10_TAIL
11. Process control: start every long-running job you may need to stop with setsid, and stop it by its process group (kill -- -<pgid>) or with pkill -P <pid>. On Linux with systemd, start it as setsid systemd-run --user --scope -q -p OOMPolicy=continue <cmd>: tmux runs each pane in a systemd scope whose default policy stops the whole pane, shell and agent included, when the kernel out-of-memory killer takes any process in it, so a job in its own scope dies alone. Never signal a pid list computed from a ps or awk walk, and never send STOP, TERM, or KILL to any process you did not start: a stray signal to the tmux server, a shell, or another agent freezes or kills the whole team. Subagent prompts carry this rule too.
EOF
}
