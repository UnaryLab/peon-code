# peon-code

A tmux session of side-by-side AI coding agent CLIs that watch and message each other's panes.

Each pane runs one agent CLI with a role. The team coordinates through a [task board](#task-board) file.

## Requirements

- macOS or Linux, with tmux 3.2 or newer and bash 3.2 or newer (the macOS default)
- At least one agent CLI: claude, codex, copilot, gemini, grok, or qwen. gemini and qwen are unverified.
- Python 3.10 or newer, only for the browser workspace

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
- A start or resume checks upstream for a newer version and asks before it pulls.

## Commands

```sh
peon-code                                    # start or attach the team of this directory
peon-code -c <file> [<session>]              # team from that config file
peon-code --single-team                      # start from the config's own agent lines, team lines skipped
peon-code <session> <cmd> [<cmd> ...]        # one pane per agent command, config ignored
peon-code resume [<session>] [<cmd> ...]     # same, each agent reopening its last conversation
peon-code msg <name|all> 'text' [<session>]  # type into agent panes
peon-code send <pane-id> 'text'|-            # agent to agent: paste into a pane and submit it
peon-code rebrief <name|all> [<session>]     # send an agent its launch brief again
peon-code compact [<name|all>] [<session>]   # send /compact, then the brief again
peon-code clear [<name|all>] [<session>]     # send /clear, then the brief again
peon-code swap <name> <cli|-> <model|-> <effort|-> [<session>]  # replace an agent's CLI, model, or effort
peon-code add <name> <role> <command...> [--session <name>] [--team <name>] [--save]  # add an agent to a running team
peon-code [-c file] add-team [--team <name>] [--save] [--session <name>]  # add a team; without -c, clone team 1
peon-code usage [<session>]                  # print token usage per agent
peon-code detach [<session>]                 # detach every client; the agents keep running
peon-code dismiss [<session>]                # print token usage, kill the session, delete its state directory
peon-code list                               # agent panes of every session
peon-code -h, --help                         # help
peon-code --version                          # print the version; must be the first argument
```

- A `<session>` defaults to the current directory's base name, with `.` and `:` replaced by `_`.
- Commands refuse a same-named session that peon-code did not create.
- The launch marks the project folder trusted in `~/.claude.json` and `~/.codex/config.toml`. The entries stay after the session ends; delete them by hand to undo.
- `--save` writes the added agent or team to the project's config files and `roles/`. It never overwrites a file or changes `~/.config/peon-code/peon-code.conf`.

## Browser workspace

```sh
peon-code-web                      # all running teams in your local browser
peon-code-web lab                  # open lab first; create it here if missing
peon-code-web --no-open            # print the URL, open no browser
peon-code-web --port 9000          # use only this port; fail if another program holds it
peon-code-web --ssh my-server      # run on your Mac against an SSH host
peon-code-web --ssh my-server --dir /remote/path --config ./team.conf
```

- `--dir PATH` creates or opens the team of that project folder, locally or on the SSH host. It asks before it creates a missing folder.
- `--config FILE` uses a local team config for a new team, for that launch only.
- `--ssh HOST` needs `peon-code-web` of this version or newer on both machines. Your SSH config and keys apply. The Mac needs no tmux.
- Keep the command running; Ctrl-C stops the server, not the agents.
- The server listens on loopback only. The launch URL grants access to the team, so keep it private.
- An SSH launch keeps its token in `~/.config/peon-code/web-<port>.url` on the host, and later SSH launches reuse it. Anyone with that host account can read it.
- Delete that file on the host to give the next SSH launch a fresh token.
- An attached terminal sets the pane size, and the browser then shows only what the terminal shows.
- After the browser sized the panes, attach with `peon-code <session>`; a plain `tmux attach` shows each agent in its own window.

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
- `compact-at <tokens>` compacts a claude or codex pane whose context reaches that size; default 250000, `0` for off.
- `restart-dead yes|no` restarts an agent whose pane falls back to a shell, at most 3 times an hour; default `yes`. An agent you quit on purpose also comes back.
- `team <name> <file>` adds a [team](#teams).
- Full-line `#` comments and blank lines are skipped; inline comments are not. A config error aborts before the session is built.

Shipped roles: `manager`, `implementer`, `reviewer`, `writer`, `director`.

A custom role file opens with frontmatter: `type:` (`manager`, `worker`, or `reviewer`) and a one-line `description:`.

### Teams

- One session can run several teams, each with its own manager, workers, reviewer, and board.
- `<file>` is relative to this config and holds agent lines only.
- Team names match `[A-Za-z0-9_-]+`, are unique, and differ from the session name, which team 1 uses.
- Agents of a later team are named `<team>-<name>`, so `impl` in team `team2` is `team2-impl`.
- `--single-team` keeps the saved `team` lines; delete a line to drop that team for good.
- With two or more teams, a `director` pane takes your input and git; managers report to it.
- A team with a `writer` writes summaries under `innovation_summary/`. In a git repository, the launcher adds that directory to `.gitignore`.

### Task board

The launcher creates `.peon-code-task.md` when at least one agent has a role. Read it to see what the team is doing; the rules are in [ARCHITECTURE.md](ARCHITECTURE.md#task-board-protocol).

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
