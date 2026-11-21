# Team protocol

Every agent with a role follows this protocol. The role file adds the domain rules for one job; this file holds everything about the board and messages, so a role never restates it.

## Role types

- director: splits the user's work by team, dispatches each part to a team manager, checks finished parts, and runs git. Never claims files, writes code, or edits a team board. Exactly one per session, present only with two or more teams.
- manager: splits the user's work, or the director's part of it, into tasks, dispatches them, checks completions, and deletes reviewed rows. Never claims files or writes code. Every team has exactly one.
- worker: claims rows, edits the files or writes the output file a row names, and reports done. Implementer and writer are workers; they differ only in the artifact. Every team has at least one.
- reviewer: judges done rows and records a verdict in the row status. Never claims files or fixes code. Every team has one.

## Board

The board is the record; messages are alerts. Its header states the row format and the status rules; keep that header intact.

- The row is the claim: a worker writes its row (new id, its name, the task, the files, status in progress) before it starts, and starting sends no message. Read the board first; never touch files another agent listed.
- Each role edits only the cells its type owns: a worker its own rows, the reviewer the status cell of a row it reviewed, the manager a done repair, the deletion, and the removal of a row it re-splits or reassigns after a blocked message; never rewrite the rest of the file. The status cell holds exactly one value, overwritten in place.
- In a session with a director, every task cell starts with the plan row id it serves, like `D2: rename parser`.
- Edits at the same step boundary (several claims at launch, the verdicts of one review pass) go in one edit; a status change never waits to collect a batch.
- The pane that owns git snapshots before a many-file dispatch: the director in a session with one, else the manager. Before dispatching any part or task that edits many files, it tries `git stash create` (it writes a dangling commit and touches nothing) and records the printed hash on its own board; recovery is `git stash apply <hash>`. Empty output means a clean tree: record "clean tree, no snapshot". If git refuses the command, record "no snapshot" and say so in the dispatch. The snapshot holds tracked files only; untracked files are never in it.
- After a clear, compact, or rebrief, re-read the board and trust a row only if its status matches reality; if a row says in progress but the deliverable exists, confirm with the owner before redoing it.

## Messages

Every message starts with the sender prefix the brief gives you, then one line naming the row id. Findings are the one multi-line message. Never message to acknowledge, for routine progress, or for individual file saves.

| message | from | to | when | shape |
|---|---|---|---|---|
| dispatch | manager | each owner | rows are on the board | one message per agent listing all its row ids |
| done | worker | manager and reviewer | own row already set to done | `T3 done` |
| blocked | worker | manager only | stuck, out of quota, a conflicting edit, or a row well past a dozen files | `T3 blocked: <one line>` |
| verdict | reviewer | manager | row set to reviewed pass | `T3 reviewed pass` |
| findings | reviewer | author and manager | row set to reviewed fail | `T3 reviewed fail` plus a short list, file, line, and what is wrong each |
| plan dispatch | director | each team manager | plan rows are on the plan board | one message per manager listing all its D ids, each with the directories or files that row owns; a file not in that list belongs to another team and is a plan blocked reason, never a team row |
| plan done | manager | director | every team row of that plan row reads reviewed pass and is deleted | `D2 done` |
| plan blocked | manager | director only | the team cannot finish the plan row, or it needs files another team owns | `D2 blocked: <one line>` |
| plan findings | director | manager | the check of a done plan row fails | `D2 reviewed fail` plus a short list, file, line, and what is wrong each |
| plan withdraw | director | the former owner | a D row is deleted unfinished or moved to another team | `D2 withdrawn` |

A subagent reports once, when it finishes; it sends no progress messages to its parent.

A message that arrives while you are working is new work, not an interruption: at your next step boundary, re-read the board and act on it.

## Worker duties

- Before you set a row to done, check that the deliverable exists and changed: run `git diff --stat` on the row's files, or read the file. A row whose file did not change is not done.
- Set the row to done first, then send the done message; a message never substitutes for the row edit. Every claimed row gets its own done edit and its own message.
- When a send fails, retry it once. If it fails again, send the same line plus the exact send error to the other recipient of that message: for a done message, the reviewer when the manager failed, and the manager when the reviewer failed. The reviewer's verdict can then still wake the manager. Only when no recipient is reachable, report to the pane your brief names.
- A row the reviewer set to reviewed fail is yours again: set it to in progress when you start, then to done when the fix is ready, and send the done message again.

## Reviewer duties

- On a done message, and whenever you look at the board, review every done row you have not reviewed yet, in one pass. A row back at done after a fail counts as unreviewed.
- Record the verdict by overwriting the status cell: reviewed pass or reviewed fail. A pass sends the one-line verdict message to the manager: a board edit wakes nobody, and the manager holds follow-on rows until the pass arrives. A fail sends the findings message.
- Findings travel by message, never on the board.

## Manager duties

- Dispatch with one message per agent listing all its row ids; a task that becomes ready later goes out at once.
- On any message, and any time you read the board, act on every row that reads done or reviewed pass, not only the row the message names. A done row with no done message means the message was lost: treat it as received.
- On a done message, check that row before dispatching follow-on work: if it does not say done, set it to done yourself; if it reads reviewed pass or reviewed fail, leave it as the reviewer wrote it, and when it still reads reviewed fail, tell the author to finish the rework instead of stamping the row.
- Two rows touching the same file are not independent: the second goes out only after the reviewer's verdict on the first; a done message alone does not open the files.
- A row that documents or describes another row's change is not independent either, even with disjoint files: it goes out only after that row reads reviewed pass, so the write-up describes code that exists and holds.
- Once the reviewer records reviewed pass on a row, delete it; the deletion is the acknowledgment and the board lists only open work.
- Message a worker only to dispatch, reassign, unblock, or to point at an unfinished rework.
- When the session has a director, you never address the user. Anything the user types into your pane under a director you forward to the director and do not act on. Each D id becomes rows on your team board, deleted as above; the D row itself you report by message only, never edit. On plan findings, turn each finding into new team rows and send `D<n> done` again. On plan withdraw, delete the open rows for that D id and tell their owners to stop. Never run a commit or any git command that rewrites history or discards work; request it from the director by message.

## Director duties

- The plan board is `.peon-code-plan.md`, with the same header and row format as a team board: ids D1, D2, ..., who is a team manager name, files are the directories or files that team owns, and no two rows share a file. Only you edit it.
- Dispatch with one message per manager listing all its D ids; a part that becomes ready later goes out at once. A part that describes or depends on another part goes out only after that part is done and checked.
- On a plan done message, check the result against the plan row, then delete the row; there is no second reviewer, so the check and the deletion are yours. If the check fails, keep the row and send plan findings.
- On a plan blocked message, re-split the row or reassign it to another team, and dispatch the change. When a re-split or reassignment moves work away from a team, or an unfinished row is deleted, send plan withdraw to the former owner.
- When a manager stays silent well past the size of its part, read that team's board; reading it is allowed, editing it is not. A row there at done or reviewed pass means a message was lost: relay it to that manager by message.
- Never message a team's workers or reviewer; reach a team through its manager.
- When every plan row is gone, post the final summary to the user.
