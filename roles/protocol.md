# Team protocol

Every agent with a role follows this protocol. The role file adds the domain rules for one job; this file holds everything about the board and messages, so a role never restates it.

## Role types

- manager: splits the user's work into tasks, dispatches them, checks completions, and deletes reviewed rows. Never claims files or writes code. Every team has exactly one.
- worker: claims rows, edits the files or writes the output file a row names, and reports done. Implementer and writer are workers; they differ only in the artifact. Every team has at least one.
- reviewer: judges done rows and records a verdict in the row status. Never claims files or fixes code. Every team has one.

## Board

The board is the record; messages are alerts. Its header states the row format and the status rules; keep that header intact.

- The row is the claim: a worker writes its row (new id, its name, the task, the files, status in progress) before it starts, and starting sends no message. Read the board first; never touch files another agent listed.
- Each role changes only its own rows: a worker its claims, the reviewer the status cell of a row it reviewed, the manager a done repair and the deletion. The status cell holds exactly one value, overwritten in place.
- Edits at the same step boundary (several claims at launch, the verdicts of one review pass) go in one edit; a status change never waits to collect a batch.
- After a clear, compact, or rebrief, re-read the board and trust a row only if its status matches reality; if a row says in progress but the deliverable exists, confirm with the owner before redoing it.

## Messages

Every message starts with the sender prefix the brief gives you, then one line naming the row id. Findings are the one multi-line message. Never message to acknowledge, for routine progress, or for individual file saves.

| message | from | to | when | shape |
|---|---|---|---|---|
| dispatch | manager | each owner | rows are on the board | one message per agent listing all its row ids |
| done | worker | manager and reviewer | own row already set to done | `T3 done` |
| blocked | worker | manager only | stuck, out of quota, or a conflicting edit | `T3 blocked: <one line>` |
| findings | reviewer | author and manager | row set to reviewed fail | `T3 reviewed fail` plus a short list, file and line each |
| commit | any non-main agent | main pane | a task or the user asks for a commit | the request |

A message that arrives while you are working is new work, not an interruption: at your next step boundary, re-read the board and act on it.

## Worker duties

- Set the row to done first, then send the done message; a message never substitutes for the row edit. Every claimed row gets its own done edit and its own message.
- A row the reviewer set to reviewed fail is yours again: set it to in progress when you start, then to done when the fix is ready, and send the done message again.
- Never commit; send the commit message instead.

## Reviewer duties

- On a done message, and whenever you look at the board, review every done row you have not reviewed yet, in one pass. A row back at done after a fail counts as unreviewed.
- Record the verdict by overwriting the status cell: reviewed pass or reviewed fail. A pass sends no message; the manager reads it from the board. A fail sends the findings message.
- Findings travel by message, never on the board.

## Manager duties

- Dispatch with one message per agent listing all its row ids; a task that becomes ready later goes out at once.
- On a done message, check that row before dispatching follow-on work: if it does not say done, set it to done yourself; if it reads reviewed pass or reviewed fail, leave it as the reviewer wrote it, and when it still reads reviewed fail, tell the author to finish the rework instead of stamping the row.
- Two rows touching the same file are not independent: the second goes out only after the reviewer's verdict on the first; a done message alone does not open the files.
- Once the reviewer records reviewed pass on a row, delete it; the deletion is the acknowledgment and the board lists only open work.
- Message a worker only to dispatch, reassign, unblock, or to point at an unfinished rework.
