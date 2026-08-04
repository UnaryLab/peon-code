# peon-code

Bash launcher that builds a tmux session of side-by-side AI coding agent CLIs (claude, codex, copilot, ...) that watch and message each other's panes.

## Layout

- `peon-code.sh`: entry point and all subcommands
- `lib/config.sh`, `lib/tmux.sh`: config parsing and tmux helpers
- `roles/*.md`: per-role prompt files
- `install.sh`: symlinks the script into a bin dir
- `tests/test_peon_code.sh`: the test suite

## Cross-platform: every feature must work on both macOS and Linux

- Target bash 3.2 (macOS default). No `declare -A`, `mapfile`/`readarray`, `${var,,}`, `${var^^}`, or other bash 4+ features.
- Use only POSIX-portable flags for external tools. BSD and GNU versions differ: avoid `sed -i` (write to a temp file and `mv`), avoid `stat`, `date -d`, `readlink -f`, `grep -P`, `mktemp` without a template.
- No platform-only tools (`pbcopy`, `open`, `xclip`, `xdg-open`) unless guarded with a fallback for the other OS.
- tmux is the only hard dependency beyond bash; require tmux >= 3.2, nothing newer.
- Before finishing any change, check the diff for the patterns above.

## Tests

- Run `tests/test_peon_code.sh`. Every behavior change updates or adds a test.
- Never run `tmux kill-server` in tests or automation; it kills the user's real sessions. Kill only sessions the test created, by name.

## Conventions

- Keep everything in bash; no new languages or dependencies.
- `shellcheck` clean.
- Comments and docs are tool-independent: never reference an assistant skill, mode, or persona (no `ponytail:` or similar prefixes). Mark a deliberate simplification with a plain comment stating the limit and the upgrade path.
