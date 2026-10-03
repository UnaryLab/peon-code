# peon-code

A tmux session of side-by-side AI coding agent CLIs that watch and message each other's panes.

## Overview

Each pane runs one agent CLI, launched with a brief that names the pane's own id, the roster of the other panes, and the agent's role. An agent reads another's latest output with `tmux capture-pane -pt <pane-id> -S -100` and messages it with `peon-code send <pane-id>`, which pastes the text into that pane's input box and submits it. The team coordinates through a task board file, see [Task board](#task-board).

## Requirements

- tmux 3.2 or newer
- bash 3.2 or newer, the macOS default
- At least one agent CLI installed (claude, codex, copilot, ...)
- macOS or Linux

## Installation

```sh
./install.sh            # symlink as peon-code into ~/.local/bin
./install.sh <bin-dir>  # symlink into another directory
```

After installation, run `peon-code` from any directory. `install.sh` seeds `~/.config/peon-code/peon-code.conf` from the example if it is missing, installs [`tmux.conf`](tmux.conf) to `~/.tmux.conf` (asking before overwriting an existing one), and prints a note when the bin directory is not on your `PATH`.

`~/.local/bin` is not on the default `PATH` on macOS. If the note appears, add this line to your shell profile (`~/.zshrc` or `~/.bashrc`) and open a new shell:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

When a newer version is available, a start or resume asks `pull now? [y/N]`. Answer `y` to update and start on the new version; any other answer starts on the current one and prints the `git pull` command to run later. A new push may take one extra start to show up.

To uninstall, run `peon-code uninstall [bin-dir]`, which removes the symlink `<bin-dir>/peon-code`, with `bin-dir` defaulting to `~/.local/bin`. The repository itself is left in place. A path that exists but does not point at this `peon-code.sh` is left alone and exits 1. Nothing there at all is reported and exits 0.

## Quick start

```sh
peon-code                                    # start or attach a team
peon-code <session>                          # custom session name
peon-code -c team.conf lab                   # session lab, team from team.conf
peon-code <session> <cmd> [<cmd> ...]        # one pane per agent command, config ignored
peon-code lab claude codex claude            # 3-agent example
peon-code resume [<session>] [<cmd> ...]     # same, each agent reopening its last conversation
peon-code dismiss [<session>]                # kill one session
peon-code detach [<session>]                 # detach every client of one session
peon-code msg <name|all> 'text' [<session>]  # send text to an agent pane
peon-code send <pane-id> 'text'|-            # agent to agent: paste into a pane and submit it
peon-code rebrief <name|all> [<session>]     # send an agent its launch brief again
peon-code compact [<name|all>] [<session>]   # send /compact, then the brief again once it ends
peon-code clear [<name|all>] [<session>]     # send /clear, then the brief again
peon-code watch [<session>] [<tokens>]        # compact a pane whose context reaches <tokens>; started by every launch
peon-code list                               # agent panes of every session
peon-code uninstall [bin-dir]                # remove the install.sh symlink
peon-code -h                                 # help
```

Every `[<session>]` argument defaults to the current directory's base name, with `.` and `:` replaced by `_`, since tmux rewrites those characters in session names. peon-code marks each session it creates; attaching and every session-scoped subcommand (`dismiss`, `detach`, `msg`, `rebrief`, `compact`, `clear`) refuse a same-named session peon-code did not create.

### Supported providers

| Provider | How it launches | How it resumes |
|----------|-----------------|----------------|
| claude | launched bare, brief pasted in once its TUI is up | `--resume <id>` |
| codex | positional prompt, stays interactive | `resume <id>` |
| copilot | `-i <prompt>` (verified) | `--resume=<id>` |
| gemini, qwen | `-i <prompt>` (unverified on this machine) | `--resume <id>` |
| anything else | command as given, brief appended as a positional prompt | not supported |

### Start and attach

`peon-code [-c file] [<session>] [<cmd> ...]` builds the session, or attaches it if it already exists. The team resolves as described under [Config file](#config-file).

The window uses tmux's `main-vertical` layout: the main agent's pane takes the left 60% of the width, the other agents stack to its right. Main is the agent marked with a leading `*` in the config, else the first agent with the `manager` role, else the first agent in the team.

Only the main agent can commit and run destructive git commands (`git reset`, `checkout`, `restore`, `switch`, `clean`, `stash`, `rm`, `commit`, `branch -D/-M/-f/--delete`, `push`, `rebase`, `reflog expire`, `update-ref`, `filter-branch`, `gc`); every other agent is denied them. The denial is enforced for claude panes and stated as a rule in the brief for other CLIs. A claude pane whose config line passes its own `--settings` or `--dangerously-skip-permissions` is not covered, and the launcher says so on stderr. See [ARCHITECTURE.md](ARCHITECTURE.md#git-denial) for the limits of the enforcement.

The terminal tab caption is `<session> : <directory>`, the directory being the base name of the active pane's current one. Other tmux sessions keep their own title setting.

The session is attached as soon as its panes exist, so the agent CLIs start while the session is on screen. Their launch notes arrive as tmux status-line messages instead of terminal output, and any startup dialog is in front of you to answer. A note that has scrolled off the status line is still readable with `tmux show-messages`, and a run started from inside an existing tmux session switches that client to the new session, so the calling shell gets its prompt back while the agents are still starting.

With no TTY on stdin (a headless caller such as a script or an agent running the launcher), the session is still built, but instead of attaching the launcher prints the session name and the `tmux attach -t <session>` command and exits 0. In that mode the agents start before the line is printed.

If any agent command does not start, its name goes to the status line and the session stays up with the failed pane in view. Headless, the launcher instead kills the new session, names the failed agents, and exits nonzero.

### Detach and reattach

From inside the session, press the tmux prefix then `d` (`Ctrl-b d` with the default prefix) to detach the current terminal.

Alternatively, `peon-code detach [<session>]` detaches every terminal attached to the session. Run it from a terminal outside the session. With no such session, or one peon-code did not create, it exits 1. The session stays alive and its agents keep running in the background, so use `dismiss` to actually stop it.

To come back, run `peon-code` again from the same directory, or `peon-code <session>` with the same session name: an existing session is attached instead of rebuilt.

### Resume

`peon-code resume [<session>] [<cmd> ...]` builds the session the same way as a plain start, except each agent reopens the conversation it had in that session and directory before, so the team keeps its memory across a `dismiss` or a reboot.

Only claude, codex, copilot, gemini, and qwen have a resume handle; any other provider starts fresh. An agent with no earlier conversation in the last 30 days is named on stderr and starts fresh too. A resumed claude pane that opens on claude's "Resume from summary" picker takes the summary default and waits out the compaction that follows before its brief is pasted. Every resumed pane still gets its full brief, since pane ids change with each session.

### Dismiss

`peon-code dismiss [<session>]` kills one session, matched exactly. Other sessions and the tmux server keep running.

With no such session it says so and exits 0. A session peon-code did not create is left alone and exits 1.

### Msg

`peon-code msg <name|all> 'text' [<session>]` sends text to the named agent's pane, or to every agent pane with `all`, prefixed `[from user]`. Teams share agent names, so reaching one session keeps `msg boss` from interrupting every team on the tmux server.

Panes are taken one at a time, each getting up to about 3 seconds for its input box to show the text before `Enter` follows. A pane in copy mode, on a dialog or a menu, or whose box holds typed text is skipped and takes no paste. A skipped pane, or one that refuses the paste or never shows it, is named on stderr and the rest still get theirs; text the box took but never showed is left there for you to submit. An unknown agent name prints the session's panes and exits 1, and a run where any pane took no message exits nonzero.

### Send

`peon-code send <pane-id> 'text'|-` is the agent-to-agent path: it pastes a message into another agent's pane and submits it. A message of `-` is read from stdin, which keeps quotes and apostrophes out of the sending agent's shell.

A busy target takes nothing: a pane holding typed text, on a dialog or a menu, or in copy mode is retried up to 10 times over about 10 seconds, then exits nonzero having pasted nothing, so that pane keeps whatever it had. A pane back at a shell, a pane peon-code did not launch, and a pane drawing no prompt marker peon-code knows exit nonzero at once. After a paste, `Enter` follows only once the box shows that message: all of it, the CLI's paste placeholder, or, for a message too long for the box, its last 100 or more characters; a box that never matches keeps the message with no `Enter` sent, and the run exits nonzero. On a busy target, retry later rather than pasting by hand.

### Rebrief

`peon-code rebrief <name|all> [<session>]` pastes the launch brief back into the named agent's pane, or every agent pane with `all`. An agent that compacts or clears its conversation loses the brief's rules, and this puts them back.

A pane whose input box holds typed text, one on a dialog or a menu, one drawing no prompt marker peon-code knows, and one from an older launch with no stored brief are each skipped with a note on stderr, and on their own do not change the exit code. The run exits nonzero when no pane took a brief at all, or when a paste was refused or left unsubmitted.

### Compact and clear

`peon-code compact [<name|all>] [<session>]` and `peon-code clear [<name|all>] [<session>]` send `/compact` or `/clear` to the named agent's pane, or to every agent pane, then paste that pane's brief back once the command has finished, since both commands drop the standing instructions. The name defaults to `all`.

If the pane you ran the command from is among the target panes, no pane is sent anything: a note on stderr tells you to run the command from a shell or another pane instead. Otherwise, a pane in copy mode, one drawing no prompt marker peon-code knows, one on a dialog or a menu, one whose input box holds typed text, or one that tmux refused the paste for is skipped with a note on stderr, and the rest still get the command. If the box holds anything other than the slash command after the paste, no `Enter` is sent and the command is left there for you to submit. Each pane that took the command then has up to 2 minutes to finish; one still busy after that keeps its brief unsent and is named on stderr, so run `rebrief` on it later. The run exits nonzero only when no pane took the command.

### Context watcher

Every launch starts `peon-code watch` in the background for its session. Once a minute it reads each claude and codex pane's context size from the usage record the CLI writes to its transcript (the input tokens of the last request, which include the system prompt, tools, and conversation) and runs `compact` on a pane that has reached the threshold, so the pane gets its brief back in the same step. The threshold is the `compact-at <tokens>` line in the team config, default 250000; `compact-at 0` turns the watcher off. A pane fires once per crossing: after a compact it waits until its reading has dropped below the threshold before it can fire again. Panes of other CLIs are named once on the status line as not watched, since they log no context size the watcher knows. The watcher exits when the session ends; `peon-code watch [<session>] [<tokens>]` starts one by hand.

### List

`peon-code list` prints every agent pane on the tmux server as `SESSION AGENT PANE STATUS`, so a session can be found without remembering the directory it was launched from. It takes no arguments and covers every session, not one.

A pane back at a shell is reported as `gone (<shell>)`: its agent exited. With no agent panes anywhere it says so. Either way it exits 0; an argument exits 1.

How the panes are identified, how text is pasted and submitted, and how `resume` finds each agent's conversation are described in [ARCHITECTURE.md](ARCHITECTURE.md).

## Reproducing results

peon-code has no experiments. Its two checks are the ones CI runs:

```sh
shellcheck -x peon-code.sh install.sh tests/test_peon_code.sh
tests/test_peon_code.sh
```

## Configuration

### Config file

Team resolution: CLI agent commands > `-c` file > `./peon-code.conf` > `~/.config/peon-code/peon-code.conf` > `claude codex`. A `-c` file that does not exist aborts; the default config files may be absent.

One agent per line: `name command... role`. The first token is the name, the last is the role, everything between is the command. For a full team, see [peon-code.conf.example](peon-code.conf.example).

```
# name   command                                      role
*boss    claude --model claude-fable-5 --effort high  manager
fast     codex                                        -
weird    claude                                       ./my-roles/chaos.md
```

- Names must match `[A-Za-z0-9_-]+` and be unique. A leading `*` marks the main agent (see [Start and attach](#start-and-attach)); at most one line may carry it.
- The role field is required. `-` means no role.
- A bare role name reads `roles/<name>.md` next to `peon-code.sh`. A role token with a `/` is a file path, relative paths resolving against the config file's directory.
- A line `compact-at <tokens>` sets the context watcher's threshold (see [Context watcher](#context-watcher)); it is the only non-agent line.
- Full-line `#` comments and blank lines are skipped. Inline comments are not.
- A role file opens with a frontmatter block: `type:` (one of `manager`, `worker`, `reviewer`), `description:` (one line, shown in the roster). The type picks the agent's duties in `roles/protocol.md`; the body below the block holds only the job-specific rules.
- Bad names, duplicate names, lines with fewer than three tokens, missing role files, a role file without a type, and a team with roles that lacks a manager-type, a worker-type, or a reviewer-type role all abort before the session is created.

Shipped roles: `manager`, `implementer`, `reviewer`, `writer`.

Types: `manager` is the manager, `implementer` and `writer` are workers, `reviewer` is the reviewer. The board and message protocol every role follows is `roles/protocol.md`; it is part of every role pane's brief.

A team with a `writer` writes its summaries under `innovation_summary/` in the working directory, one markdown file per subject. Each innovation in a write-up has four labeled segments in order: Problem, Importance, Innovation, Implementation. The reviewer checks for that structure. When that directory is a git repository, the launcher adds `innovation_summary/` to `.gitignore` if it is not already listed.

### Task board

The launcher creates `.peon-code-task.md` in the working directory if it is missing and at least one agent has a role. It is a table of `id | who | task | files | status`, one row per open task, under a header that states the editing rules the agents follow. Read it to see what the team is working on; finished rows are deleted, so the board lists only open work. The rules the agents follow are in [ARCHITECTURE.md](ARCHITECTURE.md#task-board-protocol).

A team without roles (agent commands on the command line, or a config of all `-` roles) leaves no file behind; its agents create the board themselves, with the same header, if they need it.

### Environment

peon-code reads these environment variables:

- `CLAUDE_CONFIG_DIR` and `CODEX_HOME`: the transcript stores `resume` searches for claude and codex, defaulting to `~/.claude` and `~/.codex`.
- `TMPDIR`: the directory the brief files are written under, defaulting to `/tmp`.

The tmux server captures its environment when it first starts. An agent that cannot see an environment variable you exported later is reading the older environment: run `tmux kill-server` and launch again. `dismiss` only kills one session, so the server keeps its old environment.

## Citation

No formal citation is provided. Link to the [peon-code repository](https://github.com/UnaryLab/peon-code) when referring to this project.

## License

MIT. See [LICENSE](LICENSE).
