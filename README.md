# peon-code

## Overview

A tmux session of side-by-side AI coding agent CLIs that watch and message each other's panes.

## Requirements

- tmux 3.2 or newer
- At least one agent CLI installed (claude, codex, copilot, ...)

## Installation

```sh
./install.sh                    # symlink as peon-code into ~/.local/bin
```

After installation, run `peon-code` from any directory.

`install.sh` seeds `~/.config/peon-code/peon-code.conf` from the example if it is missing.

To uninstall:

```sh
peon-code uninstall [bin-dir]   # remove the install.sh symlink
```

## Quick start

```sh
peon-code                              # session named after the current directory, team from ./peon-code.conf if present, else claude codex
peon-code <session>                    # same team resolution, custom session name
peon-code -c team.conf lab             # session lab, team from team.conf
peon-code <session> <cmd> [<cmd> ...]  # one pane per agent command, config ignored
peon-code lab claude codex claude      # 3-agent example
peon-code -h                           # help
```

## Commands

```sh
peon-code resume [<session>] [<cmd> ...]     # same, each agent reopening its last conversation
peon-code dismiss [<session>]          # kill one session, default the current directory name
peon-code msg <name|all> 'text' [<session>]  # send text to an agent pane of one session
peon-code send <pane-id> 'text'|-            # agent to agent: paste into a pane and submit it (- reads stdin)
peon-code rebrief <name|all> [<session>]     # send an agent its launch brief again
peon-code compact [<name|all>] [<session>]   # send /compact, then the brief again once it ends
peon-code clear [<name|all>] [<session>]     # send /clear, then the brief again
peon-code list                         # agent panes of every session
```

peon-code marks each session it creates and refuses to attach, message, or dismiss an unmarked session with the same name.

### Supported providers

| Provider | How it launches | How it resumes |
|----------|-----------------|----------------|
| claude | launched bare, brief pasted in once its TUI is up | `--resume <id>` |
| codex | positional prompt, stays interactive | `resume <id>` |
| copilot | `-i <prompt>` (verified) | `--resume=<id>` |
| gemini, qwen | `-i <prompt>` (unverified on this machine) | `--resume <id>` |
| anything else | passed through as-is | not supported |

Every brief is written to a file under `$TMPDIR`. A CLI that takes its prompt on the command line launches as `<cmd> "$(cat <file>)"`, so the command line stays one line instead of thousands of escaped characters; a claude pane gets that same file pasted in once its TUI is up.

A claude pane gets its brief only once its input line is drawn and the pane has stopped changing. A menu such as the folder-trust dialog counts as unsettled, so the launcher never types into it: it waits up to 30 seconds for the dialog to be answered, then prints the pane's brief file for you to paste yourself.

### Start and attach

The window uses tmux's `main-vertical` layout: the main agent's pane takes the left 60% of the width, the other agents stack to its right. Main is the agent marked with a leading `*` in the config, else the first agent with the `manager` role, else pane 0.

The session sets `set-titles` for itself, so the terminal tab caption is `<session> : <directory>`, the directory being the active pane's current one. Other tmux sessions keep their own title setting.

With no TTY on stdin (a headless caller such as a script or an agent running the launcher), the session is still built, but instead of attaching the launcher prints the session name and the `tmux attach -t <session>` command and exits 0.

If any agent command does not start, the launcher kills the new session, names the failed agents, and exits nonzero.

### Detach and reattach

Detaching is plain tmux: press `Ctrl-b d`, the default detach binding. The agents keep running in the background.

To come back, run the launcher again from the same directory (or with the same session name): an existing session is attached instead of rebuilt. From inside another tmux session it switches the client rather than nesting. `tmux attach -t <session>` works too.

Detaching leaves the session alive. Use `dismiss` to actually stop it.

### Resume

`resume` builds the session the same way as a plain start, except each agent reopens the conversation it had in that session and directory before, so the team keeps its memory across a `dismiss` or a reboot. The team, session name, and roles resolve exactly as they do for a start.

Each brief carries the phrase `agent <name> of peon-code session <session>,` (trailing comma included, so one session name that is a prefix of another never matches the other's transcripts), and that phrase is what `resume` looks for in the CLIs' own transcripts, newest first: `~/.claude/projects/<directory>/*.jsonl` for claude, `~/.codex/sessions/**/rollout-*.jsonl` for codex (the rollout must also record the current working directory), `~/.copilot/session-state/<id>/events.jsonl` for copilot (the events log must also record the current working directory), `~/.gemini/tmp/<sha256 of the directory>/chats/*.jsonl` for gemini, and `~/.qwen/projects/<directory>/chats/<id>.jsonl` for qwen. The marker is unique per agent, so a team of any size reopens one conversation per pane rather than every same-CLI pane landing in the newest one. Transcripts older than 30 days are not searched.

claude panes launch as `claude --resume <id>`; when claude opens a large or old session on its "Resume from summary" picker, the pane answers it with the summary default and waits out the compaction that follows before pasting the brief. codex panes launch as `codex resume <id>`, copilot panes as `copilot --resume=<id>`, gemini and qwen panes as `<cli> --resume <id>`, all keeping the config's own arguments; copilot, gemini, and qwen still get the brief through `-i`. Any other provider has no resume handle here and starts fresh. An agent with no earlier thread is named on stderr and starts fresh too.

Each resumed pane still gets the full brief, since pane ids change with every session.

### Dismiss

`dismiss` kills one session: the name given, else the current directory name, matched exactly. Other sessions and the tmux server keep running. With no such session it says so and exits 0.

### Msg

`msg` sends text to the named agent's pane, or to every agent pane with `all`, prefixed `[from user]`. It reaches one session: the name given as the third argument, else the current directory name. Teams share agent names, so this keeps `msg boss` from interrupting every team on the tmux server. Names live in the `@peon_name` pane option, which apps cannot overwrite; the pane title only labels the border. An unknown name aborts and prints the panes that session has.

### Send

Each agent reads another pane with `tmux capture-pane` and messages it with `peon-code send <pane-id> -`, the message on stdin. One run of `send` makes the box check and the paste back to back, and it presses `Enter` only once the box holds exactly the message.

`send` first measures the target's input box: everything from the prompt marker to the end of the cursor's row, so text the cursor was moved back over still counts. A box holding text, a menu, a dialog, and a pane in copy mode all clear on their own, so `send` retries those up to 10 times over about 10 seconds before exiting non-zero without pasting; a pane back at a shell, a pane that is not a peon-code agent pane, and a pane drawing no prompt marker peon-code knows exit non-zero at once. Into an empty box it pastes the message through its own tmux buffer, dropping every control byte but tab and newline, then polls the box for up to 2 seconds and presses `Enter` only once the box holds that message alone, either as its text or as the CLI's paste placeholder row. A box that never matches keeps the message and whatever else it holds, with no `Enter` sent, for you to sort out.

### Rebrief

`rebrief` pastes the launch brief back into the named agent's pane, or every agent pane with `all`. An agent that compacts its conversation loses the brief's rules; rebrief restores them. The brief file path lives in the `@peon_brief` pane option, set at launch; a pane from an older launch has none and is skipped with a note.

### Compact

`compact` sends `/compact` to the named agent's pane, or every agent pane by default, then pastes each pane's brief back once compaction ends, since compacting drops the standing instructions. The slash command is pasted on its own with nothing before it, and Enter follows only once the box holds the command alone, so a dialog or autocomplete list that opened after the paste does not take the Enter as its answer. A pane in copy mode, on a dialog or menu, or whose input box holds typed text is skipped with a note; the rest still get the command. Name and session default to `all` and the current directory name.

### Clear

`clear` works the same way but sends `/clear`: the conversation is wiped and the brief is pasted back right after, so the agent starts fresh with its rules intact.

### List

`list` prints every agent pane on the server as `SESSION AGENT PANE STATUS`, so a session can be found without remembering the directory it was launched from. A pane back at a shell is reported as `gone`: its agent exited.

## Reproducing results

```sh
shellcheck -x peon-code.sh install.sh tests/test_peon_code.sh
tests/test_peon_code.sh
```

## Configuration

### Config file

Team resolution: CLI agent commands > `-c` file > `./peon-code.conf` > `~/.config/peon-code/peon-code.conf` > `claude codex`. A `-c` file that does not exist aborts; the default config files may be absent.

One agent per line: `name command... role`. The first token is the name, the last is the role, everything between is the command. See [peon-code.conf.example](peon-code.conf.example).

```
# name   command                                                     role
*boss    claude --model claude-fable-5 --effort high                 manager
archie   claude --model claude-opus-5 --effort medium                reviewer
impl     codex --model gpt-5.6-luna -c model_reasoning_effort=max    implementer
scout    codex --model gpt-5.6-sol -c model_reasoning_effort=medium  explorer
weird    claude                                                      ./my-roles/chaos.md
```

- Names must match `[A-Za-z0-9_-]+` and be unique. A leading `*` marks the main agent; at most one line may carry it.
- The role field is required. `-` means no role.
- A bare role name reads `roles/<name>.md` next to `peon-code.sh`. A role token with a `/` is a file path, relative paths resolving against the config file's directory.
- Full-line `#` comments and blank lines are skipped. Inline comments are not.
- Bad names, duplicate names, lines with fewer than three tokens, and missing role files abort before the session is created.

Shipped roles: `manager`, `implementer`, `reviewer`, `explorer`.

### Task board

The launcher creates `.peon-code-task.md` in the working directory if it is missing and at least one agent has a role, a table of `who | task | files | status`. Agents record task claims and finishes there and read it before claiming files. Messages are alerts; the board is the record that lasts.

A team without roles (agent commands on the command line, or a config of all `-` roles) leaves no file behind; its agents create the board themselves if they need it.

### Environment

The tmux server captures its environment when it first starts. An agent that cannot see an environment variable you exported later is reading the older environment: run `tmux kill-server` and launch again. `dismiss` only kills one session, so the server keeps its old environment.

## Citation

No formal citation is provided. Link to the [peon-code repository](https://github.com/UnaryLab/peon-code) when referring to this project.

## License

MIT. See [LICENSE](LICENSE).
