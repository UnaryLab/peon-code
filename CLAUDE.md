# peon-code

Bash launcher that builds a tmux session of side-by-side AI coding agent CLIs (claude, codex, copilot, ...) that watch and message each other's panes.

## Layout

- `peon-code.sh`: entry point, option parsing, and subcommand dispatch
- `lib/launch.sh`: session build, agent startup, and watcher launch
- `lib/config.sh`: config file and team parsing, update check
- `lib/resume.sh`: transcript and resume-id lookup
- `lib/tmux.sh`: pane identity and readiness checks
- `lib/input.sh`: input-box parsing and safe pasting
- `lib/session.sh`: session creation, attach, detach, dismiss, and list
- `lib/commands.sh`: messaging, clear, compact, and rebrief
- `lib/mouse.sh`: selection, copying, and explanation bindings
- `peon-code-web.sh`, `web/`: optional local browser launcher, stdlib server, and static UI
- `lib/brief.sh`: launch briefs and task-board header
- `lib/watch.sh`: context watcher
- `roles/*.md`: per-role prompt files
- `install.sh`: symlinks the script into a bin dir and seeds `~/.config/peon-code/peon-code.conf`
- `tests/test_peon_code.sh`: the test suite
- `README.md`: user-facing behavior only; `ARCHITECTURE.md`: how it works inside

## Cross-platform: every feature must work on both macOS and Linux

- Target bash 3.2 (macOS default). No `declare -A`, `mapfile`/`readarray`, `${var,,}`, `${var^^}`, or other bash 4+ features.
- Use only POSIX-portable flags for external tools. BSD and GNU versions differ: avoid `sed -i` (write to a temp file and `mv`), avoid `stat`, `date -d`, `readlink -f`, `grep -P`, `mktemp` without a template.
- No platform-only tools (`pbcopy`, `open`, `xclip`, `xdg-open`) unless guarded with a fallback for the other OS.
- tmux is the only hard dependency beyond bash; require tmux >= 3.2, nothing newer.
- Before finishing any change, check the diff for the patterns above.

## Tests

- Run `tests/test_peon_code.sh`. Every behavior change updates or adds a test.
- Browser backend: `python3 -m unittest discover -s tests -p 'test_web*.py'`. Optional browser interactions: `NODE_PATH=<installed Playwright directory> node tests/test_web_browser.cjs <launch-url>`.
- Never run `tmux kill-server` in tests or automation; it kills the user's real sessions. Kill only sessions the test created, by name.

## Conventions

- Keep the terminal launcher in bash. The optional browser UI uses Python 3.10+ stdlib and buildless HTML/CSS/JS; no third-party dependencies.
- `shellcheck` clean.
- Comments and docs are tool-independent: never reference an assistant skill, mode, or persona (no `ponytail:` or similar prefixes). Mark a deliberate simplification with a plain comment stating the limit and the upgrade path.

## Creating a role

`roles/protocol.md` is the one home for the board and message rules: role types, who messages whom and when, and the duties of each type. A role file never restates any of it.

- A role file opens with frontmatter: `type:` (manager, worker, or reviewer), `description:` (one line, shown in the roster). The body holds only the domain rules of that job: what to read, what to produce, what to check.
- The config reader rejects a role file without a type and a team with roles that lacks a manager-type, a worker-type, or a reviewer-type role.
- To change how agents coordinate (claims, done, verdicts, rework, dispatch), edit `roles/protocol.md` and the seeded board header in `lib/brief.sh`, which restates the row format and status rules so they survive a compact. Keep the two consistent. The brief builder keeps only the `## <Type> duties` section matching the pane's type, so a duty every type shares goes in the Board or Messages section, and each duties heading keeps that exact form.
- A check that only one type performs (the reviewer's write-up checks, for example) lives in that role file, never in the protocol.
