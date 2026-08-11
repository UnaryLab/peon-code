# peon-code

Bash launcher that builds a tmux session of side-by-side AI coding agent CLIs (claude, codex, copilot, ...) that watch and message each other's panes.

## Layout

- `peon-code.sh`: entry point, option and subcommand dispatch, and the session build
- `lib/config.sh`: config file and team parsing, resume-id lookup
- `lib/tmux.sh`: tmux helpers and the subcommand implementations
- `roles/*.md`: per-role prompt files
- `install.sh`: symlinks the script into a bin dir and seeds `~/.config/peon-code/peon-code.conf`
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

## Creating a role

Every role (`roles/*.md` plus the shared brief text and the seeded board header in `peon-code.sh`) must encode the task-board completion rule; keep it intact when adding or editing a role:

- The board row is the record of completion, not messages. A worker sets its own row to done first, then sends the completion message; a message never substitutes for the row edit. The row is also the claim: starting a task sends no message, and alert messages are one line naming the row id ("T3 done", "T3 blocked: ...").
- A manager-type role, on receiving a completion message, verifies the sender's row is done and fixes it if not, before dispatching new work. Once it has verified the work, it deletes the row, after the reviewer records a verdict on it if the team has a reviewer; the deletion is the acknowledgment and the board lists only open work. It dispatches with one message per agent listing that agent's row ids, never one message per row.
- A reviewer-type role records its verdict in the row status, reviewed pass or reviewed fail, and no other role overwrites that status. A failed row goes back to its author, who sets it to in progress for the rework and to done again when the fix is ready; a row back at done counts as unreviewed and gets a fresh review.
- Board edits are economic: a role changes only its own rows, keeps each row to one line, and overwrites the status cell with a single value (in progress, done, reviewed pass, reviewed fail) instead of appending to it; findings and history travel by message, never on the board. Row ids (T1, T2, ...) are assigned by the row's creator and never reused. Edits at the same step boundary go in one edit, but a status change is never delayed to collect a batch. The seeded board header restates the row format and status rules so they survive a compact; roles keep that header intact rather than restating it.
- After a clear, compact, or rebrief, the role re-reads the board skeptically: if a row's deliverable already exists, confirm with the row's owner instead of re-executing the task.
