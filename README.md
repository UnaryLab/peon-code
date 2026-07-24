# peon-code

A tmux session of side-by-side AI coding agent CLIs that watch and message each other's panes.

## Requirements

- tmux
- At least one agent CLI installed (claude, codex, copilot, ...)

## Usage

```sh
./peon-code.sh                              # session "peon-code", team from ./peon-code.conf if present, else claude codex
./peon-code.sh <session>                    # same team resolution, custom session name
./peon-code.sh -c team.conf lab             # session lab, team from team.conf
./peon-code.sh <session> <cmd> [<cmd> ...]  # one pane per agent command, config ignored
./peon-code.sh lab claude codex claude      # 3-agent example
./peon-code.sh quit                         # kill the tmux server
./peon-code.sh msg <name|all> 'text'        # send text to an agent pane
./install.sh                                # symlink as peon-code into ~/.local/bin
./peon-code.sh uninstall [bin-dir]          # remove that symlink
./peon-code.sh -h                           # help
```

Team resolution: CLI agent commands > config file > `claude codex`. A `-c` file that does not exist aborts; only the default `./peon-code.conf` may be absent.

With no TTY on stdin (a headless caller such as a script or an agent running the launcher), the session is still built, but instead of attaching the launcher prints the session name and the `tmux attach -t <session>` command and exits 0.

`quit` runs `tmux kill-server`, which ends every session on the tmux server, not just peon-code's. It prints what it killed; with no server running it says so and exits 0.

`msg` sends text to the named agent's pane, or to every agent pane with `all`, prefixed `[from user]`. Names come from pane titles, which also label the pane borders. An unknown name aborts and prints the panes it found.

## Config file

One agent per line: `name command... role`. The first token is the name, the last is the role, everything between is the command. See [peon-code.conf.example](peon-code.conf.example).

```
# name   command                   role
boss     claude                    manager
impl     codex --model gpt-5       implementer
scout    codex --model gpt-5-mini  researcher
weird    claude                    ./my-roles/chaos.md
fast     claude                    -
```

- Names must match `[A-Za-z0-9_-]+` and be unique.
- The role field is required. `-` means no role.
- A bare role name reads `roles/<name>.md` next to `peon-code.sh`. A role token with a `/` is a file path, relative paths resolving against the config file's directory.
- Full-line `#` comments and blank lines are skipped. Inline comments are not.
- Bad names, duplicate names, lines with fewer than three tokens, and missing role files abort before the session is created.

Shipped roles: `manager`, `implementer`, `reviewer`, `researcher`.

## Task board

The launcher creates `.peon-tasks.md` in the working directory if it is missing, a table of `who | task | files | status`. Agents record task claims and finishes there and read it before claiming files. Messages are alerts; the board is the record that lasts.

## Supported providers

| Provider | How it launches |
|----------|-----------------|
| claude | launched bare, brief pasted in once its TUI is up |
| codex | positional prompt, stays interactive |
| copilot | `-i <prompt>` (verified) |
| gemini, qwen | `-i <prompt>` (unverified on this machine) |
| anything else | passed through as-is |

## How messaging works

Each agent reads another pane with `tmux capture-pane` and messages it with `tmux send-keys`. The message text is sent first, then after a 1-second sleep the `Enter` is sent as a separate `send-keys` call. The Enter must be separate: a same-call trailing Enter is treated by the receiver's TUI as pasted text and never submits.

## Environment

The tmux server captures its environment when it first starts. An agent that cannot see an environment variable you exported later is reading the older environment: run `./peon-code.sh quit` and launch again.

## License

MIT. See [LICENSE](LICENSE).
