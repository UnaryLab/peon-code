# peon-code

## Overview

A tmux session of side-by-side AI coding agent CLIs that watch and message each other's panes.

## Requirements

- tmux
- At least one agent CLI installed (claude, codex, copilot, ...)

## Installation

```sh
./install.sh                    # symlink as peon-code into ~/.local/bin
peon-code uninstall [bin-dir]   # remove that symlink
```

Optional: the script also runs in place as `./peon-code.sh`. `install.sh` seeds `~/.config/peon-code/peon-code.conf` from the example if it is missing.

## Quick start

```sh
peon-code                              # session named after the current directory, team from ./peon-code.conf if present, else claude codex
peon-code <session>                    # same team resolution, custom session name
peon-code -c team.conf lab             # session lab, team from team.conf
peon-code <session> <cmd> [<cmd> ...]  # one pane per agent command, config ignored
peon-code lab claude codex claude      # 3-agent example
peon-code dismiss [<session>]          # kill one session, default the current directory name
peon-code msg <name|all> 'text' [<session>]  # send text to an agent pane of one session
peon-code list                         # agent panes of every session
peon-code -h                           # help
```

Team resolution: CLI agent commands > `-c` file > `./peon-code.conf` > `~/.config/peon-code/peon-code.conf` > `claude codex`. A `-c` file that does not exist aborts; the default config files may be absent.

The session sets `set-titles` for itself, so the terminal tab caption is `<session> : <directory>`, the directory being the active pane's current one. Other tmux sessions keep their own title setting.

With no TTY on stdin (a headless caller such as a script or an agent running the launcher), the session is still built, but instead of attaching the launcher prints the session name and the `tmux attach -t <session>` command and exits 0.

If any agent command does not start, the launcher kills the new session, names the failed agents, and exits nonzero.

### Detach and reattach

Detaching is plain tmux: press `Ctrl-b d`, the default detach binding. The agents keep running in the background.

To come back, run the launcher again from the same directory (or with the same session name): an existing session is attached instead of rebuilt. From inside another tmux session it switches the client rather than nesting. `tmux attach -t <session>` works too.

Detaching leaves the session alive. Use `dismiss` to actually stop it.

`dismiss` kills one session: the name given, else the current directory name, matched exactly. Other sessions and the tmux server keep running. With no such session it says so and exits 0.

peon-code marks each session it creates and refuses to attach, message, or dismiss an unmarked session with the same name.

`msg` sends text to the named agent's pane, or to every agent pane with `all`, prefixed `[from user]`. It reaches one session: the name given as the third argument, else the current directory name. Teams share agent names, so this keeps `msg boss` from interrupting every team on the tmux server. Names live in the `@peon_name` pane option, which apps cannot overwrite; the pane title only labels the border. An unknown name aborts and prints the panes that session has.

`list` prints every agent pane on the server as `SESSION AGENT PANE STATUS`, so a session can be found without remembering the directory it was launched from. A pane back at a shell is reported as `gone`: its agent exited.

## Reproducing results

```sh
shellcheck -x peon-code.sh install.sh tests/test_peon_code.sh
tests/test_peon_code.sh
```

## Configuration

### Config file

One agent per line: `name command... role`. The first token is the name, the last is the role, everything between is the command. See [peon-code.conf.example](peon-code.conf.example).

```
# name   command                                                     role
boss     claude --model claude-fable-5 --effort high                 manager
archie   claude --model claude-opus-5 --effort medium                reviewer
impl     codex --model gpt-5.6-sol -c model_reasoning_effort=high    implementer
scout    codex --model gpt-5.6-sol -c model_reasoning_effort=medium  explorer
weird    claude                                                      ./my-roles/chaos.md
```

- Names must match `[A-Za-z0-9_-]+` and be unique.
- The role field is required. `-` means no role.
- A bare role name reads `roles/<name>.md` next to `peon-code.sh`. A role token with a `/` is a file path, relative paths resolving against the config file's directory.
- Full-line `#` comments and blank lines are skipped. Inline comments are not.
- Bad names, duplicate names, lines with fewer than three tokens, and missing role files abort before the session is created.

Shipped roles: `manager`, `implementer`, `reviewer`, `explorer`.

### Task board

The launcher creates `.peon-code-task.md` in the working directory if it is missing and at least one agent has a role, a table of `who | task | files | status`. Agents record task claims and finishes there and read it before claiming files. Messages are alerts; the board is the record that lasts.

A team without roles (agent commands on the command line, or a config of all `-` roles) leaves no file behind; its agents create the board themselves if they need it.

### Supported providers

| Provider | How it launches |
|----------|-----------------|
| claude | launched bare, brief pasted in once its TUI is up |
| codex | positional prompt, stays interactive |
| copilot | `-i <prompt>` (verified) |
| gemini, qwen | `-i <prompt>` (unverified on this machine) |
| anything else | passed through as-is |

Every brief is written to a file under `$TMPDIR`, and the pane launches with `<cmd> "$(cat <file>)"`, so the command line stays one line instead of thousands of escaped characters.

A claude pane gets its brief only once its input line is drawn and the pane has stopped changing. A menu such as the folder-trust dialog counts as unsettled, so the launcher never types into it: it waits up to 30 seconds for the dialog to be answered, then prints the pane's brief file for you to paste yourself.

### How messaging works

Each agent reads another pane with `tmux capture-pane` and messages it with `tmux send-keys`. The message text is sent first, then after a 1-second sleep the `Enter` is sent as a separate `send-keys` call. The Enter must be separate: a same-call trailing Enter is treated by the receiver's TUI as pasted text and never submits.

### Environment

The tmux server captures its environment when it first starts. An agent that cannot see an environment variable you exported later is reading the older environment: run `tmux kill-server` and launch again. `dismiss` only kills one session, so the server keeps its old environment.

## Citation

No formal citation is provided. Link to the [peon-code repository](https://github.com/UnaryLab/peon-code) when referring to this project.

## License

MIT. See [LICENSE](LICENSE).
