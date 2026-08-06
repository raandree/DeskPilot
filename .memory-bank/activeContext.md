---
schema-version: 1
status: accepted
owner: shared
last-verified: 2026-08-05
source: repository evidence
---

# Active Context

## Current focus

**An open modal has to re-read the change set (`ai/git-workbench`, 2026-08-06).**
The user reported that undoing a file "sometimes doesn't work": they confirmed the
undo and the file was still listed, still showed its old diff, and still offered
another **Undo this file**. Nothing was wrong with the working tree — the sidebar
had already updated. `diffView.files` was a snapshot taken when the viewer opened
and nothing re-derived it.

New pure helper `reconcileDiffFiles` in `web/assets/diff.js` rebuilds the viewer's
list from the current change sets: files that no longer differ drop out, survivors
are replaced by their **fresh** record (the stale one carries the wrong
`snapshotSha`, so the diff would be taken against the wrong base), the selection
follows its file or moves to the next survivor, and an empty result tells the
caller to close the viewer. `refreshDiffViewer()` now runs after every Keep and
Undo.

The same defect had a backend half: `POST /api/git/restore` put the bytes back but
left the file in the pending change set, so a Git-path undo kept it listed as an
unreviewed DeskPilot change. It now clears exactly what went back, the way the
commit route already did.

Before this: an unpriced Model reading as `$0.0000`, and before that the **Save**
action — DeskPilot's user-facing word for a commit.

## Verification

- `reconcileDiffFiles` covered under Node: the fresh record replaces the stale
  one, an undone selection lands on the next survivor, a surviving selection
  stays put, a trailing undone selection clamps to the last survivor, an empty
  result signals "close the viewer", and junk input does not throw.
- A structural guard asserts the wiring exists in `app.js` — the pure helper
  passing on its own would not prove the viewer ever calls it.
- New `tests/Unit/GitRestoreRoute.Tests.ps1` (3/3): the route reverts a tracked
  file, drops it from the pending set and persists the store, and leaves a file
  pending when the restore skipped it.
- Full unit suite **565/565**, exit 0.

## Next step

Live-smoke the fix in the browser: open the diff viewer over several changed
files, undo one from the footer, and confirm it leaves the rail while the
selection moves on — then undo the last one and confirm the viewer closes.
Spec 100 records the competitive gap analysis; the recommended next pieces are
per-call Tool approval, an installer, and scheduled tasks.

## Recent fix

An unpriced Model read as a confident `$0.0000 · 0 credits`. The Engine returns
`$null` when its price table has no rate for the Model id; DeskPilot coerced that
to zero. The boundary now carries a `priced` flag and the counters carry
`unpricedTurns`, so a floor says so.

## Previous focus

DeskPilot remembering what it changed until the user decides: a pre-Turn
snapshot commit under `refs/deskpilot/snapshots/` plus a per-Project pending
change set in `changes.json`, surfaced in the Message card, the Changes panel,
the file tree, and the diff viewer.
