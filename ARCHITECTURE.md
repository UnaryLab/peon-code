# Architecture

How peon-code works inside. For what it does from the user's side, see [README.md](README.md).

## Pane identity

Each agent pane carries its name in the `@peon_name` tmux pane option and its brief file path in `@peon_brief`, both set at launch; an app cannot overwrite a pane option, unlike the pane title, so the pane border shows `@peon_name` too. Every subcommand acts only on panes carrying `@peon_name`, and the session-scoped ones only on sessions marked `@peon_code`.

## Pasting

Text goes in through a tmux buffer as a bracketed paste, so a multi-line message stays in the input line instead of submitting early.

## The busy check

A pane's input box is read as everything from the prompt marker (claude draws `❯`, codex `›`) to the end of the cursor's row, with the CLI's hint text left out, so text the cursor was moved back over still counts. `Enter` follows a paste only once the box reads back the pasted text or the CLI's placeholder row for a long paste, such as `[Pasted text #2 +15 lines]`.

## Briefs

Every brief is written to a file under `$TMPDIR`. A CLI that takes its prompt on the command line launches as `<cmd> "$(cat <file>)"`, so the command line stays one line instead of thousands of escaped characters. A pane that opens on the folder-trust check a CLI asks on its first visit to a directory waits for you to answer it in the attached session. A claude pane gets its brief pasted in once that dialog is gone, its input line is drawn, and the pane has stopped changing: any other menu or dialog counts as unsettled, so the launcher waits up to 30 seconds (2 minutes when resuming) and then names the pane in a status message telling you to run `peon-code rebrief <name>`.

## Git denial

Only the main agent launches with full git. Every other agent launches with commit and the destructive git commands denied (`git reset`, `checkout`, `restore`, `switch`, `clean`, `stash`, `rm`, `commit`, `branch -D/-M/-f/--delete`, `push`, `rebase`, `reflog expire`, `update-ref`, `filter-branch`, `gc`): a claude pane gets a `--settings` deny file that also binds every subagent it spawns; other CLIs have no launch-time permission file, so they get a hard prohibition line in their brief, which their subagents do not see. Denying `git commit` on every other pane keeps commits in the main pane, which is what the shared brief rule tells the agents. The deny rules cover Bash commands only, not file writes, and a pane can rewrite the deny file or relaunch its CLI without it. The deny file goes only to a pane whose command starts with the literal token `claude`. The deny rules match literal command prefixes, so they do not block git invoked with a global flag such as `git -C <dir> reset` or `git --work-tree=<dir> clean`. A claude pane whose config line already passes `--settings` keeps that file and gets no deny file, and a pane passing `--dangerously-skip-permissions` gets the deny file but ignores it; both cases print a line to stderr at launch.

## Terminal title

The session sets `set-titles` for itself, so the terminal tab caption is `<session> : <directory>`, the directory being the base name of the active pane's current one. Other tmux sessions keep their own title setting.

## Resume lookup

Each brief carries the phrase `agent <name> of peon-code session <session>,`, trailing comma included, so one session name that is a prefix of another never matches the other's transcripts. `resume` searches each CLI's own transcript store for that phrase, newest first, over the last 30 days: every `*.jsonl` file under `~/.claude/projects/<path>/`, `~/.codex/sessions/`, `~/.copilot/session-state/`, `~/.gemini/tmp/<sha256 of the working-directory path>/chats/`, and `~/.qwen/projects/<path>/chats/`, where `<path>` is the full working-directory path with every character other than letters and digits replaced by `-`. The codex and copilot stores hold every directory's transcripts, so a match there must also record the current working directory. The marker is unique per agent and session, so every pane reopens its own conversation rather than same-CLI panes landing in the newest one.

## Update check

On a start or resume, the launcher compares its own checkout's `HEAD` with the upstream refs the last fetch left and offers a fast-forward pull when it is behind. A `y` pulls and restarts the launcher with the same arguments, because bash reads the script lazily and a file rewritten under it can execute a mix of old and new lines. A current checkout starts a quiet `git fetch` in the background for the next start, so a start never waits on the network and a push shows up one start late. The other subcommands never touch git.

## Task board protocol

The board file opens with a header stating the editing rules, above a table of `id | who | task | files | status`: one row per task, edited in place by its owner; ids (`T1`, `T2`, ...) are assigned by the row's creator and never reused; the status cell holds exactly one of in progress, done, reviewed pass, reviewed fail, and a status change overwrites the cell rather than appending to it; findings travel by message, not on the board. Because the header rides in the file, agents re-read the rules every time they read the board, so the rules survive a clear or compact. The row is the claim: an agent writes its claim before starting, sends no start message, and does not touch files another agent listed. Messages are alerts, one line naming the row id (`T3 done`, `T3 blocked: ...`); the board is the record that lasts. Edits that fall at the same moment, like several claims at launch, go in one edit, but a status change is never delayed to batch it with another. An agent sets its own row to done before sending its completion message; a message never substitutes for the row edit. The main pane's brief adds a verification duty: on a completion message it checks the sender's row and sets it to done itself if the sender did not, before dispatching new work, and it dispatches with one message per agent listing that agent's row ids. Once the work is verified it deletes the row, after the reviewer records a verdict on it if the team has one; the deletion is the acknowledgment, so the board lists only open work. After a clear, compact, or rebrief, an agent trusts a row only if its status matches reality, and confirms with the owner before redoing work a row shows as still open but that already looks done.
