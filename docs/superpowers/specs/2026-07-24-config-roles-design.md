# peon-code: config file with named agents and roles

Date: 2026-07-24. Status: approved design, pending implementation.

## Goal

Let a config file define the agent team: each pane gets a unique name (so
two claude panes are distinguishable) and an optional role prompt (manager,
designer, verification, ...) injected into its brief.

## Config file

Default path `./peon-code.conf`; override with `-c <file>`.

One agent per line, whitespace-separated (spaces or tabs, `read -ra` under
default IFS):

```
# name     command                 role
boss       claude                  manager
archie     claude                  designer
impl       codex --model gpt-5     implementer
weirdo     claude                  ./my-roles/chaos.md
fast       codex --model gpt-5-mini -
```

Parse rule: first token = name, last token = role, everything between =
command. The role field is mandatory; `-` means "no role". This makes
2-token lines a parse error instead of a silent misparse, and lets commands
end in any word without it being eaten as a role.

- Full-line `#` comments and blank lines are skipped. No inline comments.
- Names must match `[A-Za-z0-9_-]+` and be unique; violations abort with an
  error naming the bad line.
- A line with fewer than 3 tokens aborts with an error.

## Roles

Shipped library: `roles/` next to peon-code.sh, one markdown file per role,
each a short prompt stating responsibilities and how to work with the team:

- `manager` - decompose the user's task onto the task board, assign, track,
  write no code; route by strength (mechanical well-specified work to codex
  panes, design/debug/review to claude panes, per the roster).
- `implementer` - build what is specified.
- `reviewer` - check diffs and finished work against the requirement.
- `researcher` - read code/docs and summarize for the team.

Rarer roles are user-written files referenced by path.

Resolution of the role token:

- contains `/`: a file path; relative paths resolve against the config
  file's directory.
- bare name: `<script-dir>/roles/<name>.md`. No other fallback dirs.
- `-`: no role section in the brief.
- unresolvable role file: abort before creating the tmux session.

## CLI

```
peon-code.sh [-c file] [session] [agent-cmd ...]
peon-code.sh quit
peon-code.sh msg <name|all> 'text'
peon-code.sh -h
```

`quit` and `msg` are reserved subcommands (a session cannot take those
names):

- `quit` runs `tmux kill-server`, ending every session on the current tmux
  server, not just peon-code's. It prints what it killed; if no server is
  running it says so and exits 0.
- `msg` delivers text to the named agent's pane (or every agent pane with
  `all`), prefixed `[from user]`, via `tmux load-buffer` + `paste-buffer -p`
  + separate Enter after a 1s sleep. Names resolve via pane titles: the
  launcher sets each pane's title to its agent name (`select-pane -T`),
  and msg looks them up with `list-panes -a -F '#{pane_id} #{pane_title}'`.
  Unknown name aborts, printing the panes it did find. Pane titles also
  label the pane borders for the human.
- `-h` prints the usage block.

Headless callers (no TTY on stdin, e.g. a peon-chat persona running the
script): skip the final attach/switch, print the session name and the
`tmux attach -t <session>` command instead, exit 0. The session is built
either way.

Options parsed with `getopts` before positionals. Precedence: CLI agent
args > config file > built-in default (claude codex).

- `peon-code.sh` - session peon-code, team from ./peon-code.conf if
  present, else claude+codex.
- `peon-code.sh lab` - session lab, same team resolution.
- `peon-code.sh -c team.conf lab` - session lab, team from team.conf; a
  missing `-c` file aborts (only the implicit ./peon-code.conf may be
  absent).
- `peon-code.sh lab claude codex` - CLI agents win; config ignored; names
  fall back to the command string (today's behavior, backward compatible).

## Script changes

- Parallel arrays `NAMES`, `CMDS`, `ROLES` replace the single `AGENTS`
  array. The launch-syntax case statement keys on `${CMDS[$i]%% *}` (the
  command's binary), never the name, so copilot/gemini/qwen keep `-i`.
- Brief: "You are NAME (COMMAND) in pane %N ..."; when name equals command
  (CLI-args mode) the parenthetical is dropped. Roster line per pane:
  `pane %id: NAME (COMMAND) - ROLE`. Message tag: `[from NAME %id]`.
- Role file content is read into a variable and interpolated as a
  "Your role:" section inside the existing heredoc, so `EOF` lines,
  backticks, and quotes in role files are inert; `printf %q` still quotes
  the whole brief for launch.
- The split loop runs `tmux select-layout -t "$SESSION":agents tiled` after
  each split so 6-10 pane teams do not fail with "pane too small".
- Each pane's title is set to its agent name at launch (`select-pane -T`),
  used by `msg` for name lookup and shown on pane borders.
- The launcher creates `.peon-tasks.md` in the working directory (header
  table: who | task | files | status) if absent; the brief tells agents to
  record task claims and finishes there and to grep it before claiming
  files. Messages alert; the board is the durable record.

## Brief rules

The brief keeps today's roster + messaging protocol and adds, in this
order:

1. Task intake: the user assigns work by typing into the manager pane
   (pane 0 if no manager). That agent decomposes onto the task board;
   the others wait for a board entry or message instead of inventing
   work at launch. The decomposing agent posts the final summary.
2. Git discipline: never `git add -A`, commit, or run destructive git
   commands unless the user asks; stage only files you claimed; one agent
   touches git at a time.
3. Look before sending: capture the target pane first; if it shows a
   dialog or menu, wait and retry later; never type into it.
4. Dead-pane guard: if `tmux display -pt <id> '#{pane_current_command}'`
   shows a shell, the agent is dead; do not send (text would execute as
   shell commands), tell the user instead.
5. Literal sends: `tmux send-keys -t <id> -l -- 'message'` so key-name
   words and leading dashes are not interpreted; Enter still sent
   separately after a 1s sleep.
6. No idle deadlocks: if blocked, message once, work on something else,
   re-check once; then proceed on best judgment or surface to the user.
7. Rate limits: on hitting a usage limit, note it and the reset time on
   the task board so others reassign.

## Errors

All config/role errors abort before `tmux new-session`, so a bad config
never leaves a half-built session. Messages name the config line or role
path at fault.

## Testing

1. `shellcheck peon-code.sh`.
2. Parse checks without tmux: duplicate name, 2-token line, bad name
   charset, missing role file each abort with the right message.
3. Smoke run: 3-agent conf into a throwaway session; `capture-pane` each
   pane to verify name, role text, and roster landed; kill session.
4. Backward-compat run: `peon-code.sh test claude codex` with no config
   behaves as today.
5. `peon-code.sh quit` kills the server; run again with no server, it
   reports that and exits 0.
6. `peon-code.sh msg <name> 'hello'` lands `[from user] hello` in the named
   pane and submits; `msg all` reaches every pane; unknown name aborts.

## README

Update usage for config/roles/quit/msg, document the `-` role sentinel,
and add a note: the tmux server captures its environment at first
launch; if an agent cannot see an env var exported later, `peon-code.sh
quit` and relaunch.

## Out of scope

The idle-notification fix (bare launch + paste-buffer brief delivery) is a
separate pending change to the same launch loop; land this first, then
that.
