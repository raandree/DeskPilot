---
schema-version: 1
status: accepted
owner: shared
last-verified: 2026-08-09
source: repository evidence
---

# Active Context

## Current focus

**Green build restored on `main` (2026-08-09).** `./build.ps1 -Tasks build,test`
was failing 2 of 748. The tests were right and the code was wrong: merge
**665b260** (Intercom PR #4) carried the worktree revert of **42641d7** — the
2026-08-06 "undo doesn't work" fix — into `main` while keeping that commit's
tests, so the suite reported its own regression.

Only the *call sites* were lost; `reconcileDiffFiles` survived in `diff.js`. The
`gitRestore` route stopped clearing a restored file from the pending change set,
and `app.js` lost the import, `refreshDiffViewer` and its two callers. Restored
verbatim from 42641d7 rather than rewritten, along with the CHANGELOG entry and
the two `systemPatterns` entries that were reverted with it. **No test was
changed.** Full suite **748/748**, build EXIT 0.

The *Known repository state* note below is therefore resolved: the revert is
gone from `main`.

## Previous focus — Intercom inline keyboards

**Tap instead of type (`ai/intercom`, 2026-08-09).**
Parity with BotFather: a closed choice should be a button, not a number to read
and retype at a bus stop. Buttons ride under an Ask-User question and the
`/chats` listing; the written form always still works, so nothing depends on them
rendering.

The three constraints that shaped the code:

- **`callback_data` is capped at 64 bytes**, so it carries a prefix, a nonce and
  an index rather than the label. `Get-DpIntercomKeyboard` drops the *whole*
  keyboard when a button would exceed it — a button that fails silently when
  tapped is worse than no button.
- **Old buttons never disappear.** Telegram leaves them on screen indefinitely, so
  an option tap carries `PendingQuestion.token` and is refused when it does not
  match. Without that, a tap on a question answered hours ago would answer
  whatever is waiting now.
- **A tap must be acknowledged**, or Telegram shows the button spinning forever.
  `answerCallbackQuery` is queued ahead of the reply and bypasses the hourly cap;
  the pump gained a general `operation`/`payload` record so a bare Bot API call
  rides the same single-send queue and nothing waits on the accept thread.

Buttons are offered **only** for a single-question, single-select Ask-User. A
multi-select keeps the written-reply flow: one tap cannot say "these two", and a
keyboard that silently drops the second choice is worse than none.

Before this, **Checkpoints**: the pre-Turn snapshot DeskPilot already took, made
addressable from the transcript as a **Restore Checkpoint** divider, restorable
from the window and from Intercom's `/undo`. The restore is bounded to the paths
in `activity.filesWritten` rather than a folder-wide checkout, so hand edits made
in between survive — the boundary the pending change set exists to draw (spec
090). `Get-DpCheckpointSha` stops `Remove-DpChangeEntry` garbage-collecting a
snapshot a Message still references.

## Verification

- `tests/Unit/IntercomKeyboard.Tests.ps1` — **19/19**: layout and per-row packing,
  the 64-byte drop, label truncation, a tap parsed as its own kind, a tap from a
  chat that is not allow-listed rejected before its data is read, the
  `answerCallbackQuery` queued first, the *label* submitted rather than the index,
  a stale nonce and an out-of-range index both refused, chat switching, and the
  keyboard offered only for a single-select single question.
- `tests/Unit/Checkpoint.Tests.ps1` — **21/21** under `Set-StrictMode -Version
  Latest`: sha collection and per-Project filtering, truncation and the returned
  prompt, the bounded file set handed to the undo, pending-change clearing,
  refusal of a vanished or assistant Message, the no-snapshot and no-Project
  paths, `-SkipFiles`, `-Preview` changing nothing, an intact Conversation when
  the git restore fails, and `/undo`'s preview-then-confirm, its refusals (Turn
  running, bound Conversation gone, archived, no Checkpoint) and that it takes
  the **most recent** Checkpoint.
- A ref-protection guard in `tests/Unit/DeskPilot.Helpers.Tests.ps1`: Keeping a
  change does not delete a snapshot a Checkpoint still restores from (the sibling
  test proves the same inputs *do* delete it without one).
- SPA structural guards in `tests/Unit/WebAssets.Tests.ps1`: the divider is gated
  on `m.checkpoint.sha`, restoring always confirms, the prompt is put back in the
  composer, and `refreshCurrentConversation` calls `syncCheckpointDividers`.
- Full suite **748/748** after the revert was undone; before that, 735/737 with
  the two failures caused by it.
- PSScriptAnalyzer clean on every new source file; `./build.ps1 -Tasks build,test`
  EXIT 0.
- **Not yet live-smoked.** Restoring rewrites files on disk, and the keyboard path
  has never touched a real Bot API; exercise both against a real Project and a
  real bot before trusting them.

## Known repository state — not mine

`.memory-bank/progress.md`, `.memory-bank/systemPatterns.md`, `CHANGELOG.md` and
the `gitRestore` case in `Invoke-DpRouteHandler.ps1` carried a wholesale revert
of the 2026-08-06 "undo doesn't work" fix — uncommitted at first, then carried
into `ai/intercom` and merged to `main` as **665b260**. **Resolved on
2026-08-09** by restoring 42641d7's hunks verbatim. Nothing outstanding here.

## Next step

Restart DeskPilot — the whole process, not just the browser tab: the SPA
hot-reloads from `source/web` but the module functions are already in memory,
which is why the first Checkpoint attempt showed no divider. Then live-smoke
against a real bot: an Ask-User question with options should arrive with tappable
buttons that answer it in one tap, `/chats` should switch on a tap, and a tap on
an older question's buttons should be refused rather than misrouted. Then a
Checkpoint restore from both surfaces — confirm the divider appears on the turn
just run, the prompt returns to the composer, a file the agent wrote is put back
and one it created is deleted, a hand edit to an untouched file survives, and
`/undo` previews accurate numbers before `/undo confirm` acts. Also live-smoke
the restored undo path: confirming an undo in the diff viewer should drop the
file from the modal's list rather than leave it there with a second Undo button.

## Previous focus — Intercom

**Intercom — remote control from a phone (spec 110).** Telegram bot, long-polling
only, no inbound port and no relay. `Update-DpIntercomState` never waits on the
accept thread — every call is an `HttpClient` `Task` started on one tick and
reaped on a later one — and it runs from the idle tick *and* from
`Invoke-DpPendingRequest`, because the moment Intercom matters most is mid-Turn.
Only the idle-tick caller passes `-AllowTurn`, so a command arriving mid-Turn is
queued rather than re-entering `Invoke-DpTurn`. Silence was made legible by
*editing* one status message on a timer (Telegram does not notify on an edit) that
always states its next check-in deadline, so a dead machine freezes it in the past.
Before that: an open modal re-reading the change set, and an unpriced Model
reading as `$0.0000`.
