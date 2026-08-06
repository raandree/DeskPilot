---
schema-version: 1
status: accepted
owner: shared
last-verified: 2026-08-05
source: repository evidence
---

# Active Context

## Current focus

**DeskPilot now remembers what it changed, until the user decides
(`ai/git-workbench`, 2026-08-06).** The reviewer asked for "another layer on top
of Git that lets me keep or undo what the AI did and clearly see it". Git alone
cannot answer that: it only knows what differs from the last commit, so an undo
would also discard the user's own work.

DeskPilot now takes a **snapshot before every Turn** - an ordinary commit object
built in a throwaway `GIT_INDEX_FILE` and parked under
`refs/deskpilot/snapshots/` - and keeps a **pending change set** per Project in
`changes.json`. Every file a Turn writes joins it, against that snapshot, and
stays until the user **Keeps** it (accept, without committing) or **Undoes** it
(`git restore --worktree --source=<snapshot>`, or delete for a file the agent
created). A file already tracked keeps its *original* snapshot, so undo always
means "before DeskPilot first touched it".

It is visible in four places: the Changes card under the Message that made the
changes, a two-section panel under the Git bar (unreviewed DeskPilot changes vs.
merely uncommitted), the file tree (status colour, letter, folder counts, and an
accent edge for an unreviewed change), and the diff viewer - which diffs a
pending file against its snapshot.

Before this, the Git Workbench shipped: merge/branch/sync wizards, the diff
viewer, and the conflict prompt.

Nine new Private helpers plus seven routes under `/api/git/`. `Invoke-DpGitCommand`
was hardened: closed stdin, `GIT_TERMINAL_PROMPT=0`, `GIT_LITERAL_PATHSPECS=1`,
deadline-bounded async reads, process disposal, and a timeout on **every** call —
the accept loop is single-threaded, so a blocked git call froze the whole UI.

## Verification

- Full Sampler build + Pester green (**532/532**, 0 warnings, exit 0).
- Real-repository tests cover the snapshot leaving the index and working tree
  untouched, undo restoring to the snapshot rather than HEAD (a hand edit made
  before the Turn survives), deleting a file the agent created, undoing a subset,
  reporting a hand-reverted file as `unchanged`, diffing against the snapshot,
  and dropping the snapshot ref once the change is kept.
- Plus the earlier Git Workbench coverage: change set, commit, branch
  create/switch/delete, sync, a two-clone conflict, a subdirectory Project.
- An independent agent-security review of the Workfbench returned four Majors,
  all fixed.

## Next step

Live-smoke the new routes in the browser (Changes card, diff viewer, Branch
Wizard, a real sync). Spec 100 records the competitive gap analysis — the
recommended next pieces are per-call Tool approval, an installer, and scheduled
tasks.

## Previous focus

Ask-User rendered a bundled Questionnaire wizard; the Project chip derives its
visible leaf from the selected Workspace Folder.
