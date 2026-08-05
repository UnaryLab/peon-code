# peon-code

A tmux session of side-by-side AI coding agent CLIs that watch and message each other's panes.

## Overview

Each pane runs one agent CLI, launched with a brief that names the pane's own id, the roster of the other panes, and the agent's role. An agent reads another's latest output with `tmux capture-pane -pt <pane-id> -S -100` and messages it with `peon-code send <pane-id>`, which pastes the text into that pane's input box and submits it. The team coordinates through a task board file, see [Task board](#task-board).

## Requirements

- tmux 3.2 or newer
- At least one agent CLI installed (claude, codex, copilot, ...)

## Installation

```sh
./install.sh            # symlink as peon-code into ~/.local/bin
./install.sh <bin-dir>  # symlink into another directory
```

After installation, run `peon-code` from any directory. `install.sh` seeds `~/.config/peon-code/peon-code.conf` from the example if it is missing, and prints a note when the bin directory is not on your `PATH`.

To uninstall, run `peon-code uninstall [bin-dir]`, which removes the symlink `<bin-dir>/peon-code`, with `bin-dir` defaulting to `~/.local/bin`. The repository itself is left in place. A path that exists but does not point at this `peon-code.sh` is left alone and exits 1. Nothing there at all is reported and exits 0.

## Quick start

```sh
peon-code                                    # session named after the current directory
peon-code <session>                          # custom session name
peon-code -c team.conf lab                   # session lab, team from team.conf
peon-code <session> <cmd> [<cmd> ...]        # one pane per agent command, config ignored
peon-code lab claude codex claude            # 3-agent example
peon-code resume [<session>] [<cmd> ...]     # same, each agent reopening its last conversation
peon-code dismiss [<session>]                # kill one session
peon-code msg <name|all> 'text' [<session>]  # send text to an agent pane
peon-code send <pane-id> 'text'|-            # agent to agent: paste into a pane and submit it
peon-code rebrief <name|all> [<session>]     # send an agent its launch brief again
peon-code compact [<name|all>] [<session>]   # send /compact, then the brief again once it ends
peon-code clear [<name|all>] [<session>]     # send /clear, then the brief again
peon-code list                               # agent panes of every session
peon-code uninstall [bin-dir]                # remove the install.sh symlink
peon-code -h                                 # help
```

Every `[<session>]` argument defaults to the current directory name. peon-code marks each session it creates and refuses to attach to, message, or dismiss an unmarked session with the same name.

### Supported providers

| Provider | How it launches | How it resumes |
|----------|-----------------|----------------|
| claude | launched bare, brief pasted in once its TUI is up | `--resume <id>` |
| codex | positional prompt, stays interactive | `resume <id>` |
| copilot | `-i <prompt>` (verified) | `--resume=<id>` |
| gemini, qwen | `-i <prompt>` (unverified on this machine) | `--resume <id>` |
| anything else | passed through as-is | not supported |

### Start and attach

`peon-code [-c file] [<session>] [<cmd> ...]` builds the session, or attaches it if it already exists. The team resolves as described under [Config file](#config-file).

The window uses tmux's `main-vertical` layout: the main agent's pane takes the left 60% of the width, the other agents stack to its right. Main is the agent marked with a leading `*` in the config, else the first agent with the `manager` role, else pane 0.

The session sets `set-titles` for itself, so the terminal tab caption is `<session> : <directory>`, the directory being the active pane's current one. Other tmux sessions keep their own title setting.

With no TTY on stdin (a headless caller such as a script or an agent running the launcher), the session is still built, but instead of attaching the launcher prints the session name and the `tmux attach -t <session>` command and exits 0.

If any agent command does not start, the launcher kills the new session, names the failed agents, and exits nonzero.

### Detach and reattach

Detaching is plain tmux: press `Ctrl-b d`, the default detach binding. The session stays alive and its agents keep running in the background, so use `dismiss` to actually stop it.

To come back, run the launcher again from the same directory (or with the same session name): an existing session is attached instead of rebuilt. From inside another tmux session it switches the client rather than nesting. `tmux attach -t <session>` works too.

### Resume

`peon-code resume [<session>] [<cmd> ...]` builds the session the same way as a plain start, except each agent reopens the conversation it had in that session and directory before, so the team keeps its memory across a `dismiss` or a reboot.

Only claude, codex, copilot, gemini, and qwen have a resume handle; any other provider starts fresh. An agent with no earlier conversation in the last 30 days is named on stderr and starts fresh too. A resumed claude pane that opens on claude's "Resume from summary" picker takes the summary default and waits out the compaction that follows before its brief is pasted. Every resumed pane still gets its full brief, since pane ids change with each session.

### Dismiss

`peon-code dismiss [<session>]` kills one session, matched exactly. Other sessions and the tmux server keep running.

With no such session it says so and exits 0. A session peon-code did not create is left alone and exits 1.

### Msg

`peon-code msg <name|all> 'text' [<session>]` sends text to the named agent's pane, or to every agent pane with `all`, prefixed `[from user]`. Teams share agent names, so reaching one session keeps `msg boss` from interrupting every team on the tmux server.

Panes are taken one at a time, each getting up to about 3 seconds for its input box to show the text before `Enter` follows. A pane that refuses the paste, never shows it, or sits in copy mode is named on stderr and the rest still get theirs; the text is left in that pane's box for you to submit. An unknown agent name prints the session's panes and exits 1, and a run where any pane took no message exits nonzero.

### Send

`peon-code send <pane-id> 'text'|-` is the agent-to-agent path: it pastes a message into another agent's pane and submits it. A message of `-` is read from stdin, which keeps quotes and apostrophes out of the sending agent's shell.

A busy target takes nothing: a pane holding typed text, on a dialog or a menu, or in copy mode is retried up to 10 times over about 10 seconds, then exits nonzero having pasted nothing, so that pane keeps whatever it had. A pane back at a shell, a pane peon-code did not launch, and a pane drawing no prompt marker peon-code knows exit nonzero at once. After a paste, `Enter` follows only once the box holds that message alone; a box that never matches keeps the message with no `Enter` sent, and the run exits nonzero. On a busy target, retry later rather than pasting by hand.

### Rebrief

`peon-code rebrief <name|all> [<session>]` pastes the launch brief back into the named agent's pane, or every agent pane with `all`. An agent that compacts or clears its conversation loses the brief's rules, and this puts them back.

A pane whose input box holds typed text, one on a dialog or a menu, one drawing no prompt marker peon-code knows, and one from an older launch with no stored brief are each skipped with a note on stderr, and on their own do not change the exit code. The run exits nonzero when no pane took a brief at all, or when a paste was refused or left unsubmitted.

### Compact and clear

`peon-code compact [<name|all>] [<session>]` and `peon-code clear [<name|all>] [<session>]` send `/compact` or `/clear` to the named agent's pane, or to every agent pane, then paste that pane's brief back once the command has finished, since both commands drop the standing instructions. The name defaults to `all`.

A pane in copy mode, one drawing no prompt marker peon-code knows, one on a dialog or a menu, one whose input box holds typed text, or one that tmux refused the paste for is skipped with a note on stderr, and the rest still get the command. If the box holds anything other than the slash command after the paste, no `Enter` is sent and the command is left there for you to submit. Each pane that took the command then has up to 2 minutes to finish; one still busy after that keeps its brief unsent and is named on stderr, so run `rebrief` on it later. The run exits nonzero only when no pane took the command.

### List

`peon-code list` prints every agent pane on the tmux server as `SESSION AGENT PANE STATUS`, so a session can be found without remembering the directory it was launched from. It takes no arguments and covers every session, not one.

A pane back at a shell is reported as `gone (<shell>)`: its agent exited. With no agent panes anywhere it says so. Either way it exits 0; an argument exits 1.

### How it works

- **Pane identity.** Each agent pane carries its name in the `@peon_name` tmux pane option and its brief file path in `@peon_brief`, both set at launch; an app cannot overwrite a pane option, unlike the pane title, which only labels the border. Every subcommand acts only on panes carrying `@peon_name`, and the session-scoped ones only on sessions marked `@peon_code`.
- **Pasting.** Text goes in through a tmux buffer as a bracketed paste, so a multi-line message stays in the input line instead of submitting early.
- **The busy check.** A pane's input box is read as everything from the prompt marker (claude draws `❯`, codex `›`) to the end of the cursor's row, with the CLI's hint text left out, so text the cursor was moved back over still counts. `Enter` follows a paste only once the box reads back the pasted text or the CLI's placeholder row for a long paste, such as `[Pasted text #2 +15 lines]`.
- **Briefs.** Every brief is written to a file under `$TMPDIR`. A CLI that takes its prompt on the command line launches as `<cmd> "$(cat <file>)"`, so the command line stays one line instead of thousands of escaped characters. A claude pane gets its brief pasted in once its input line is drawn and the pane has stopped changing: a menu such as the folder-trust dialog counts as unsettled, so the launcher waits up to 30 seconds (2 minutes when resuming) and then prints the brief file path for you to paste yourself.
- **Resume lookup.** Each brief carries the phrase `agent <name> of peon-code session <session>,`, trailing comma included, so one session name that is a prefix of another never matches the other's transcripts. `resume` searches each CLI's own transcript store for that phrase, newest first, over the last 30 days: every `*.jsonl` file under `~/.claude/projects/<path>/`, under `~/.codex/sessions/` and under `~/.copilot/session-state/` (the last two must also record the current working directory), under `~/.gemini/tmp/<sha256 of the working-directory path>/chats/`, and under `~/.qwen/projects/<path>/chats/`, where `<path>` is the full working-directory path with every character other than letters and digits replaced by `-`. The marker is unique per agent and session, so every pane reopens its own conversation rather than same-CLI panes landing in the newest one.

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
- Full-line `#` comments and blank lines are skipped. Inline comments are not.
- Bad names, duplicate names, lines with fewer than three tokens, and missing role files abort before the session is created.

Shipped roles: `manager`, `implementer`, `reviewer`, `explorer`.

### Task board

The launcher creates `.peon-code-task.md` in the working directory if it is missing and at least one agent has a role, a table of `who | task | files | status`. Agents record task claims and finishes there and read it before claiming files. Messages are alerts; the board is the record that lasts.

A team without roles (agent commands on the command line, or a config of all `-` roles) leaves no file behind; its agents create the board themselves if they need it.

### Environment

peon-code reads these environment variables:

- `CLAUDE_CONFIG_DIR` and `CODEX_HOME`: the transcript stores `resume` searches for claude and codex, defaulting to `~/.claude` and `~/.codex`.
- `TMPDIR`: the directory the brief files are written under, defaulting to `/tmp`.

The tmux server captures its environment when it first starts. An agent that cannot see an environment variable you exported later is reading the older environment: run `tmux kill-server` and launch again. `dismiss` only kills one session, so the server keeps its old environment.

## Citation

No formal citation is provided. Link to the [peon-code repository](https://github.com/UnaryLab/peon-code) when referring to this project.

## License

MIT. See [LICENSE](LICENSE).
