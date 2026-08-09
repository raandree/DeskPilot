---
schema-version: 1
status: accepted
owner: shared
last-verified: 2026-08-09
source: repository evidence
---

# Active Context

## Current focus

**Checkpoints — rewind a Conversation to before a prompt (`ai/intercom`,
2026-08-09).** Parity with GitHub Copilot's "Restore Checkpoint" divider.

The feature needed **no new capture**: DeskPilot has committed a pre-Turn
snapshot to `refs/deskpilot/snapshots/<assistantMessageId>` since the change set
shipped, so a single file could be undone. The sha simply was not reachable from
the transcript. `Invoke-DpTurn` now stamps `checkpoint = @{ sha; root;
createdUtc }` on the **user** Message and the SPA renders a divider above it.

The two decisions that shaped the code:

- **Restore what the agent wrote, not where you are.** Only the paths from each
  discarded Message's `activity.filesWritten` are put back, through the existing
  per-file `Invoke-DpChangeUndo` against that sha. A folder-wide checkout or a
  `git reset` would destroy the hand edits made in between — the exact boundary
  the pending change set draws between "undo what the AI did" and "revert to the
  last commit" (spec 090).
- **The snapshot now has two owners.** `Remove-DpChangeEntry` deleted the ref as
  soon as its pending entries cleared, so Keeping a change would have destroyed
  the commit its own Checkpoint restores from. `Get-DpCheckpointSha` reads the
  **live** Conversation store rather than taking a parameter, so a future call
  site cannot forget to ask before deleting.

Truncation reuses `Reset-DpConversationForRerun` — the same machinery as
Regenerate and Edit — so the discarded prompt comes back in the composer.

## Verification

- `tests/Unit/Checkpoint.Tests.ps1` — **13/13** under `Set-StrictMode -Version
  Latest`: sha collection and per-Project filtering, truncation and the returned
  prompt, the bounded file set handed to the undo, pending-change clearing,
  refusal of a vanished or assistant Message, the no-snapshot and no-Project
  paths, `-SkipFiles`, and an intact Conversation when the git restore fails.
- One SPA structural guard in `tests/Unit/WebAssets.Tests.ps1`: the divider is
  gated on `m.checkpoint.sha`, restoring always confirms, and the prompt is put
  back in the composer.
- Full suite **706/708**. The two failures are the **pre-existing revert** — see
  *Known repository state* below.
- PSScriptAnalyzer clean on the new files; `./build.ps1 -Tasks build` EXIT 0 with
  both functions and the route present in the built module.
- **Not yet live-smoked.** Restoring rewrites files on disk; exercise it against a
  real Project before trusting it.

## Known repository state — not mine

`.memory-bank/progress.md`, `.memory-bank/systemPatterns.md`, `CHANGELOG.md` and
the `gitRestore` case in `Invoke-DpRouteHandler.ps1` carried **uncommitted
deletions before this session started**: a wholesale revert of the 2026-08-06
"undo doesn't work" fix. `refreshDiffViewer` is gone from `app.js` and the
`Remove-DpChangeEntry` block is gone from the `gitRestore` route, so those two
tests fail. It was left untouched on purpose — it is unrelated in-progress work —
and it has since been **carried into `ai/intercom` by this session's commits**, so
it is now in HEAD rather than sitting in the worktree. The two failures are
therefore a branch-level condition, not a dirty tree. Decide whether to restore
the fix or keep the revert before the next release.

## Next step

Restart DeskPilot (the module is rebuilt) and reload the tab, then live-smoke a
Checkpoint restore against a real Project: confirm the divider appears, that the
prompt returns to the composer, that a file the agent wrote is put back and one
it created is deleted, and that a hand edit to an untouched file survives. Then
live-smoke Intercom end to end against a real bot per
`docs/intercom-getting-started.md`. Then resolve the worktree revert above.

## Previous focus

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
