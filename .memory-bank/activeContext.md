---
schema-version: 1
status: accepted
owner: shared
last-verified: 2026-08-05
source: repository evidence
---

# Active Context

## Current focus

**A non-expert can now save their work (`ai/git-workbench`, 2026-08-06).** The
Git Workbench shipped Keep and Undo but no way to *commit*: `POST /api/git/commit`
existed and no line of the SPA called it. So the target user could review the
agent's edits and put them back, but nothing they kept ever became durable, and
Sync and Merge stayed permanently blocked on a dirty working tree.

DeskPilot now has a **Save** action — its user-facing word for a commit. One
modal over the whole Project: every uncommitted file with its `+`/`−` counts, an
editable one-line description prefilled from the change set, and one button that
commits the lot. Reachable from the Changes panel (**Save all…**), the Branch
Wizard when the tree is dirty, and the command palette. Per-file and per-hunk
staging stay out — that is precisely the vocabulary this surface removes.

Two backend corrections came with it. `git add -A` without a pathspec stages the
**whole repository**, so a Project inside a larger repository was pulling the
rest of it into the commit; it is now `git add -A -- .`. And the route clears
exactly the files it committed from the pending change set, because a committed
file is a reviewed file — otherwise DeskPilot kept calling a saved file
unreviewed and offered an undo that now contradicts history.

Before this: the pre-Turn snapshot and pending change set, and before that the
Git Workbench itself (merge/branch/sync wizards, diff viewer, conflict prompt).

## Verification

- New `tests/Unit/GitCommitRoute.Tests.ps1` green (4/4): a bulk save commits
  everything and reports it Project-relative; a committed file leaves the pending
  set and the store is persisted; a partial commit leaves the other file pending;
  an empty message is refused without touching the pending set.
- Helper coverage extended: `Invoke-DpGitCommit` reports the committed files, and
  a Project that is a subdirectory saves only its own file while the sibling
  folder's change survives.
- Full Sampler build + Pester green.

## Next step

Live-smoke the Save modal in the browser (Changes panel, Branch Wizard, palette,
and a Project inside a bigger repository). Spec 100 records the competitive gap
analysis — the recommended next pieces are per-call Tool approval, an installer,
and scheduled tasks.

## Previous focus

DeskPilot remembering what it changed until the user decides: a pre-Turn
snapshot commit under `refs/deskpilot/snapshots/` plus a per-Project pending
change set in `changes.json`, surfaced in the Message card, the Changes panel,
the file tree, and the diff viewer.
