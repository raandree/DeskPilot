---
schema-version: 1
status: accepted
owner: shared
last-verified: 2026-08-05
source: repository evidence
---

# Active Context

## Current focus

**The Git Workbench shipped on `ai/git-workbench` (2026-08-05).** DeskPilot could
already merge a Branch with AI conflict help (spec 070), but a user could not see
*what the agent had changed*, could not read a real diff, could not keep the work,
and had no way to create, delete, or sync a Branch. Spec 090 closes that.

Three surfaces: a **Changes card** under the newest assistant Message
(`N files changed +A −D`, one row per file, **Keep** = commit exactly those files,
**Undo** = revert); a **Diff viewer** with old/new line-number gutters and a file
list to step through the set; and a **Branch Wizard** covering create, switch,
delete, merge, and sync in plain language (*get* / *send* rather than pull/push).
On a conflict outside the Merge Wizard, DeskPilot **generates a prompt** and shows
it for review — it is never sent automatically.

After first use the reviewer said the Git bar's "N changes" button was easy to
overlook and that folder records did not work, so the changed files now appear
**directly**: a Changes list under the Git bar, and per-row colour + status in the
file tree (a folder shows how many changed files are inside). Untracked files are
listed individually again — a collapsed folder record is not something a diff or a
commit can act on — with the 500-file cap applied while building and only reported
files measured.

Nine new Private helpers plus seven routes under `/api/git/`. `Invoke-DpGitCommand`
was hardened: closed stdin, `GIT_TERMINAL_PROMPT=0`, `GIT_LITERAL_PATHSPECS=1`,
deadline-bounded async reads, process disposal, and a timeout on **every** call —
the accept loop is single-threaded, so a blocked git call froze the whole UI.

## Verification

- Full Sampler build + Pester green; PSScriptAnalyzer 0 warnings.
- Real-repository tests cover the change set (counts, untracked, deleted,
  renamed, conflicted, filters, the cap), commit/nothing-to-commit, branch
  create/switch/delete (incl. the unmerged refusal and force), sync
  publish/ahead/pull/autostash, a genuine two-clone conflict, and a Project that
  is a **subdirectory** of the repository.
- `diff.js` is pure and unit-tested under Node (gutter numbering, single-line
  hunk headers, new-file rows, path splitting, commit-message suggestion).
- An independent agent-security review returned four Majors, all fixed:
  an option-shaped branch name reaching `git push --delete`; unbounded untracked
  expansion on the accept thread; an autostash unwind that reported a failed
  `stash pop` as restored; and residual hang paths in the git runner.

## Next step

Live-smoke the new routes in the browser (Changes card, diff viewer, Branch
Wizard, a real sync). Spec 100 records the competitive gap analysis — the
recommended next pieces are per-call Tool approval, an installer, and scheduled
tasks.

## Previous focus

Ask-User rendered a bundled Questionnaire wizard; the Project chip derives its
visible leaf from the selected Workspace Folder.
