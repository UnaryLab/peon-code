# peon-code

A tmux session of side-by-side AI coding agent CLIs that watch and message each other's panes.

## Requirements

- tmux
- At least one agent CLI installed (claude, codex, copilot, ...)

## Usage

```sh
./peon-code.sh                              # session "peon-code", agents: claude codex
./peon-code.sh <session>                    # same agents, custom session name
./peon-code.sh <session> <cmd> [<cmd> ...]  # one pane per agent command
./peon-code.sh lab claude codex claude      # 3-agent example
```

## Supported providers

| Provider | How it launches |
|----------|-----------------|
| claude, codex | positional prompt, stays interactive |
| copilot | `-i <prompt>` (verified) |
| gemini, qwen | `-i <prompt>` (unverified on this machine) |
| anything else | passed through as-is |

## How messaging works

Each agent reads another pane with `tmux capture-pane` and messages it with `tmux send-keys`. The message text is sent first, then after a 1-second sleep the `Enter` is sent as a separate `send-keys` call. The Enter must be separate: a same-call trailing Enter is treated by the receiver's TUI as pasted text and never submits.

## License

MIT. See [LICENSE](LICENSE).
