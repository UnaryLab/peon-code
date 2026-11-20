# peon-code

A tmux session of side-by-side AI coding agent CLIs that watch and message each other's panes.

Each pane runs one agent CLI. Its launch brief names the pane's own id, the other panes, and the agent's role. An agent reads another pane with `tmux capture-pane -pt <pane-id> -S -100` and messages it with `peon-code send <pane-id>`. The team coordinates through a [task board](#task-board) file.

## Requirements

- macOS or Linux, with tmux 3.2 or newer and bash 3.2 or newer (the macOS default)
- At least one agent CLI: claude, codex, copilot, gemini, grok, or qwen; any other CLI gets its brief as a positional prompt and cannot resume. The copilot launch is verified; gemini and qwen are unverified.
- Python 3.10 or newer, only for the browser workspace
- To add a CLI, copy a file in `lib/cli/` to `<name>.sh`, rename its functions to the `<name>_` prefix, and run `tests/test_peon_code.sh`. `<name>` is the bare command name; a path such as `/opt/bin/foo` matches no provider. [ARCHITECTURE.md](ARCHITECTURE.md#adding-a-cli) lists what each function must print. peon-code has no experiments. CI runs `shellcheck -x peon-code.sh peon-code-web.sh install.sh tests/test_peon_code.sh`, then `tests/test_peon_code.sh`, then `python3 -m unittest discover -s tests -p 'test_web*.py'`.

## Installation

```sh
./install.sh            # symlink peon-code and peon-code-web into ~/.local/bin
./install.sh <bin-dir>  # symlink into another directory
peon-code uninstall [bin-dir]  # remove both symlinks; the clone stays
```

- The installer offers to install a missing tmux. For missing Python or agent CLIs it prints the install commands only.
- It seeds `~/.config/peon-code/peon-code.conf` from the example if that file is missing.
- It installs [`tmux.conf`](tmux.conf) to `~/.tmux.conf`, asking before an overwrite. It makes Shift+Enter add a new line; a terminal that sends no modified keys needs the agent's own setup.
- `~/.local/bin` is not on the default macOS `PATH`. If the installer says so, add `export PATH="$HOME/.local/bin:$PATH"` to `~/.zshrc` or `~/.bashrc`.
- A start or resume asks upstream for a newer version, waiting at most 3 seconds, then tries your clone's remote. It asks `update available upstream; pull now? [y/N]`; any other answer, or no answer from either remote, starts the current version.

## Quick start

```sh
peon-code                         # start or attach the team of this directory
peon-code -c team.conf lab        # session lab, team from team.conf
peon-code msg boss 'fix the parser'  # type into one agent's pane
peon-code dismiss                 # print token usage, then kill the session
peon-code-web --ssh my-server     # the same teams in your local browser
```

A `<session>` defaults to the current directory's base name, with `.` and `:` replaced by `_`. Commands refuse a same-named session that peon-code did not create. An interrupted launch removes its half-built session.

## Commands

### Start and attach

`peon-code [-c file] [--single-team] [<session>] [<cmd> ...]` builds the session, or attaches it if it exists. The team resolves as in [Config file](#config-file); `<cmd> ...` starts one pane per command and ignores the config. `--single-team` starts from the config's own agent lines; its `team` lines are skipped, not edited. Options must come before the flag.

- The main agent gets the left 60% of the window: the director with two or more teams, else the `*` agent, else the first manager, else the first agent. All teams share one window.
- Only the main agent may commit or run destructive git commands. Claude panes are blocked; other CLIs get a rule in the brief. A claude line with its own `--settings` or `--dangerously-skip-permissions` is not blocked. See [Git denial](ARCHITECTURE.md#git-denial).
- The launch marks the project folder trusted in `~/.claude.json` and `~/.codex/config.toml`. The entries stay after the session ends; delete them by hand to undo.
- Launch notes go to the tmux status line; `tmux show-messages` shows older ones. On Linux with systemd, an agent survives the out-of-memory killer taking one of its child processes.
- Without a terminal, the launcher prints `tmux attach -t <session>` and exits 0, or kills the session and exits nonzero when an agent fails.

### Session commands

- `peon-code detach`, run from outside, or the tmux prefix then `d`, detaches; the agents keep running. Run `peon-code` again to reattach.
- `peon-code resume` starts like a plain start, but each agent reopens its last conversation of this session and directory: claude, codex, copilot, gemini, grok, and qwen. An agent with no conversation in the last 30 days starts fresh and is named on stderr.
- `peon-code usage` prints input, cache read, cache write, output, and total tokens per agent, then per CLI, counting the newest conversation plus its subagent threads. Only claude and codex log usage. `peon-code dismiss` prints the same report, then kills that one session and deletes its state directory (see [Environment](#environment)). `peon-code list` prints every agent pane on the tmux server; a pane back at a shell shows `gone (<shell>)`.
- `peon-code msg <name|all> 'text'` types into agent panes, prefixed `[from user]`. `peon-code send <pane-id> 'text'|-` is the agent-to-agent path; `-` reads stdin. A pane in copy mode, on a dialog or a menu, or with typed text takes nothing: `msg` skips it, and `send` retries for about 10 seconds, then exits nonzero. When a box never shows the text, no `Enter` is sent; do not paste it again by hand.
- An agent that compacts or clears loses its brief. `peon-code rebrief <name|all>` pastes it again. `peon-code compact` and `peon-code clear` send `/compact` or `/clear`, then the brief; the name defaults to `all`. Busy panes are skipped with a note. Run these from a shell or another pane. A pane still busy 2 minutes after the slash command gets no brief; rebrief it later.
- `peon-code swap <name> <cli|-> <model|-> <effort|->` replaces an agent's CLI, model, or effort in its pane; `-` keeps a value. Only claude and codex can be swapped. Keeping the CLI keeps its flags and resumes the conversation; a new CLI starts bare and fresh. A headless test run must pass within 60 seconds first; on failure the agent keeps running. The swap fails when the old agent holds typed text or a dialog, or does not quit within 30 seconds. You cannot swap your own pane.

### Add agents and teams

- `peon-code add <name> <role> <command...>` adds an agent in a new pane; every word after the role is the command. `<role>` is `-`, a shipped role, or a role file path; a bare unshipped name reads `./roles/<name>.md`. A team has one manager. The name must be new and not `director`, and the command cannot contain `--session`.
- `peon-code [-c file] add-team` adds a whole team from the `-c` file, or clones team 1 from the session's config. The first added team starts the director; the main pane must be a manager, and the director runs its command. Team 1's manager keeps git access until it is swapped or restarted.
- `--team` picks the team for `add`, the caller's team, else team 1, and names the new team for `add-team`; that default is in [Teams](#teams).
- `--save` keeps the result for future launches. `add` appends to the session's config in the project folder, else writes `peon-code.conf` there, and copies a custom role to `roles/`. `add-team` writes `peon-code.<team>.conf` and adds a `team` line. Neither overwrites a file or changes `~/.config/peon-code/peon-code.conf`.

### Context watcher

Each launch starts `peon-code watch`. It compacts a claude or codex pane whose context reaches `compact-at`, default 250000 tokens. It restarts an agent whose pane falls back to a shell, at most 3 times per hour, resuming when it can. An agent you quit on purpose also comes back. `compact-at 0` and `restart-dead no` together start no watcher. Run `watch` by hand only after you kill the running one.

### Command reference

```sh
peon-code                                    # start or attach a team
peon-code -c <file> [<session>]              # team from that config file
peon-code --single-team                      # start from the config's own agent lines, team lines skipped
peon-code <session> <cmd> [<cmd> ...]        # one pane per agent command, config ignored
peon-code resume [<session>] [<cmd> ...]     # same, each agent reopening its last conversation
peon-code dismiss [<session>]                # print the session's token usage, then kill it
peon-code usage [<session>]                  # print token usage per agent of one session
peon-code detach [<session>]                 # detach every client of one session
peon-code msg <name|all> 'text' [<session>]  # send text to an agent pane
peon-code send <pane-id> 'text'|-            # agent to agent: paste into a pane and submit it
peon-code explain <pane-id>                  # explain selected text from stdin in the same pane
peon-code key [--submit] <pane-id> <name>    # press Tab, Up, Down, Left, Right, Enter, Escape, BSpace, or C-c (Ctrl+C)
peon-code rebrief <name|all> [<session>]     # send an agent its launch brief again
peon-code swap <name> <cli|-> <model|-> <effort|-> [<session>]  # replace an agent's CLI, model, or effort
peon-code add <name> <role> <command...> [--session <name>] [--team <name>] [--save]  # add an agent to a running team
peon-code [-c file] add-team [--team <name>] [--save] [--session <name>]  # add a team to a running session; without -c, clone team 1
peon-code compact [<name|all>] [<session>]   # send /compact, then the brief again once it ends
peon-code clear [<name|all>] [<session>]     # send /clear, then the brief again
peon-code watch [<session>] [<tokens>]       # compact a pane whose context reaches <tokens> and restart dead agents; started by each launch unless both are off
peon-code list                               # agent panes of every session
peon-code statusline [<user-command>]        # internal: the claude status line wrapper the launch installs
peon-code uninstall [bin-dir]                # remove both installed command symlinks
peon-code -h, --help                         # help
peon-code --version                          # print the version; must be the first argument
```

## Browser workspace

```sh
peon-code-web                      # all running teams in your local browser
peon-code-web lab                  # only the existing session lab
peon-code-web --no-open            # print the URL, open no browser
peon-code-web --port 9000          # use only this port
peon-code-web --ssh my-server      # run on your Mac against an SSH host
peon-code-web --ssh my-server --dir /remote/path --config ./team.conf
```

- `--dir PATH` creates or opens the team of that project folder, locally or on the SSH host. It asks before it creates a missing folder. The folder name is the session name unless you give one.
- `--config FILE` uses a local team config for a new team, for that launch only. Over SSH it is uploaded to `~/.config/peon-code/uploads/` on the host.
- `--port N` fails if port N is busy. Without it, the server takes 8765 or a free port; over SSH it uses the first free port of 8765 to 8774.
- `--ssh HOST` needs `peon-code-web` of this version or newer on both machines. Your SSH config and keys apply. The Mac needs no tmux.
- Keep the command running; Ctrl-C stops the server, not the agents. It listens on loopback only. The launch URL grants access to the team, so keep it private.
- Uploads go to `<project>/upload/` by default, at most 64 MiB per file, and never replace a file. Downloads stay inside the project folder, at most 256 MiB per file or zipped folder.
- An attached terminal sets the pane size, and the browser then shows only what the terminal shows. After the browser sized the panes, attach with `peon-code <session>`; a plain `tmux attach` shows each agent in its own window.

## Configuration

### Config file

Team resolution: CLI agent commands > `-c` file > `./peon-code.conf` > `~/.config/peon-code/peon-code.conf` > `claude codex`. One agent per line, `name command... role`; see [peon-code.conf.example](peon-code.conf.example).

```
# name   command                                      role
*boss    claude --model claude-fable-5 --effort high  manager
fast     codex                                        -
weird    claude                                       ./my-roles/chaos.md
```

- Names match `[A-Za-z0-9_-]+` and are unique. `director` is reserved. A leading `*` marks the main agent, on one line at most.
- The role is required; `-` means none. A bare role name reads `roles/<name>.md` next to `peon-code.sh`, else next to the config. A role with a `/` is a path relative to the config.
- `compact-at <tokens>` sets the [watcher](#context-watcher) threshold, `0` for off. `restart-dead yes|no` turns restarts on or off, default `yes`. `team <name> <file>` adds a [team](#teams). Full-line `#` comments and blank lines are skipped; inline comments are not. A config error aborts before the session is built.

Shipped roles: `manager`, `implementer`, `reviewer`, `writer`, `director`.

A role file opens with frontmatter: `type:` and a one-line `description:`. Types: `manager`, `worker` (`implementer` and `writer`), and `reviewer`. `director` is reserved for the shipped director role, so no config line, `add`, or `add-team` can use it. A team with roles needs one manager, one worker, and one reviewer. The protocol every role follows is `roles/protocol.md`.

### Teams

- `team <name> <file>` in the config adds a team. One session can run several teams, each with its own manager, workers, reviewer, and board. The main config's agents are team 1 and keep bare names.
- `<file>` is relative to this config and holds agent lines only. A `team`, `compact-at`, or `restart-dead` line in it is ignored with a warning, and so is a `*` mark.
- Team names match `[A-Za-z0-9_-]+`, are unique, and differ from the session name, which team 1 uses.
- Agents of a later team are named `<team>-<name>`, so `impl` in team `team2` is `team2-impl`. An added team without a name gets the first free one of `team2`, `team3`, and so on.
- A single-team start keeps the saved team line; delete the line to drop the team for good.
- With two or more teams, the session adds a `director` pane. It takes the main slot, your input, and git; managers report to it. It runs team 1's manager command, or team 1's first agent's command when team 1 has no roles. Change it with [`swap director`](#session-commands).
- To add a team to a running session, see [Add agents and teams](#add-agents-and-teams). A team with a `writer` writes summaries under `innovation_summary/`, one markdown file per subject. In a git repository, the launcher adds that directory to `.gitignore`.

### Task board

The launcher creates `.peon-code-task.md` when at least one agent has a role. It is a table of `id | who | task | files | status`, one row per open task. Read it to see what the team is doing; the rules are in [ARCHITECTURE.md](ARCHITECTURE.md#task-board-protocol). With several teams, each later team gets `.peon-code-task.<team>.md`, and the director plans on `.peon-code-plan.md`.

### Environment

- `CLAUDE_CONFIG_DIR`, `CODEX_HOME`: where claude and codex keep transcripts, `.claude.json`, and `config.toml`; default `~/.claude` (but `~/.claude.json`) and `~/.codex`.
- `PEON_CODE_SESSION`: set in every pane to the session name, for hooks.
- `XDG_STATE_HOME`: briefs and the watcher log go under `$XDG_STATE_HOME/peon-code/<session>/`, default `~/.local/state/peon-code/<session>/`.
- `PEON_UPDATE_URL`, `PEON_FETCH_TIMEOUT`: the update check's upstream, default `https://github.com/UnaryLab/peon-code.git`, and time limit, default 3 seconds.
- The tmux server keeps the environment it started with. If an agent cannot see a variable you exported later, run `tmux kill-server` and launch again.

## Citation

No formal citation is provided. Link to the [peon-code repository](https://github.com/UnaryLab/peon-code) when referring to this project.

## License

MIT. See [LICENSE](LICENSE).
