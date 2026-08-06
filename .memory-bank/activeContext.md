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

A ✨ button beside the description asks the Model to write it, the way GitHub
Copilot's commit box does (`POST /api/git/commit/message`): a pure-reasoning Turn
with every Tool disabled, prompted with the change set plus a bounded diff
excerpt fenced as data rather than instructions, cleaned to one line by the same
cleaner the auto-title uses. On an explicit click only, and it fills the box
rather than saving — the user still approves the words.

Two backend corrections came with it. `git add -A` without a pathspec stages the
**whole repository**, so a Project inside a larger repository was pulling the
rest of it into the commit; it is now `git add -A -- .`. And the route clears
exactly the files it committed from the pending change set, because a committed
file is a reviewed file — otherwise DeskPilot kept calling a saved file
unreviewed and offered an undo that now contradicts history.

Before this: the pre-Turn snapshot and pending change set, and before that the
Git Workbench itself (merge/branch/sync wizards, diff viewer, conflict prompt).

## Verification

- `tests/Unit/GitCommitRoute.Tests.ps1` green (10/10): a bulk save commits
  everything and reports it Project-relative; a committed file leaves the pending
  set and the store is persisted; a partial commit leaves the other file pending;
  an empty message is refused without touching the pending set; the suggestion
  route returns one clean line, frees the Runspace, reports an Engine failure and
  an unusable answer as 502s, and spends no Turn on a clean tree or while another
  Turn is running.
- `New-DpCommitMessagePrompt` covered for the file list, the caps on both axes,
  binary files, the data-not-instructions fencing, and an empty change set.
- Helper coverage extended: `Invoke-DpGitCommit` reports the committed files, and
  a Project that is a subdirectory saves only its own file while the sibling
  folder's change survives.
- Full Sampler build + Pester green.

## Next step

Live-smoke the Save modal in the browser (Changes panel, Branch Wizard, palette,
the ✨ suggestion against a real change set, and a Project inside a bigger
repository). Spec 100 records the competitive gap analysis — the recommended next
pieces are per-call Tool approval, an installer, and scheduled tasks.

## Recent fix

The Branch Wizard listed `origin` — the *remote* — as a Branch. Git abbreviates
`refs/remotes/origin/HEAD` to plain `origin`, so the old `*/HEAD` filter on the
short name never matched. Both remote reads now ask for `%(refname)` and go
through `ConvertFrom-DpRemoteRefName`. The unit tests had mocked a string git
never emits, so a real-clone test now backs them up.

## Previous focus

DeskPilot remembering what it changed until the user decides: a pre-Turn
snapshot commit under `refs/deskpilot/snapshots/` plus a per-Project pending
change set in `changes.json`, surfaced in the Message card, the Changes panel,
the file tree, and the diff viewer.
