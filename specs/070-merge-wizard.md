# Spec 070 — Branch Merge Wizard

> Status: signed off 2026-06-12 (grill-me interview). Implements a non-expert
> branch-merge flow on top of the existing Git bar. Companion: spec 080 (Clone
> Wizard). Use canonical glossary terms only.

## Purpose

Let a non-expert merge a **Branch** into the repository's **Default Branch**
(main, else master) from DeskPilot's Git bar: see at a glance whether a Branch is
already merged, preview the incoming commits, merge on approval, optionally push
the result and delete the remote Branch behind a separate confirm, clean up the
local Branch, and fall back to an AI-proposed **Merge Plan** on conflict.

Success: a user with no git-CLI knowledge merges and cleans up a feature Branch
without leaving DeskPilot or corrupting the repo.

## Decisions (from the interview)

| Topic | Decision |
| --- | --- |
| Merge target & "merged?" basis | The Default Branch: `origin/HEAD`, else local `main`, else `master`. |
| Remote scope | Local + push the Default Branch and delete the remote Branch, behind a **separate explicit confirm**. |
| Conflict handling | The AI **proposes** a Merge Plan; the user approves before any file is written. |
| Delta preview | The list of incoming commits (`sha`, subject, author, date). |
| Merge strategy | Fast-forward if possible, else a merge commit (git default). |
| Preconditions | On a dirty tree / Default Branch behind origin, offer an autofix: stash -> ff-from-origin -> merge -> pop; abort safely if the pull conflicts. |
| Cleanup | Auto-delete the local Branch (after switching to the Default Branch); remote push + delete behind a separate confirm. |
| Badge source | `git fetch` from origin first, then compare; degrade to a local-only comparison when there is no remote or the fetch fails. |
| Branch picker | Lists local + remote-only Branches; remote-only ones are marked. |
| Entry point | A "Merge into main..." action in the existing Git bar. |
| Apply conflict plan | DeskPilot writes the AI's resolved file contents, then stages + commits (the AI runs no git). |
| Conflict Turn | A pure-reasoning Turn with all Tools disabled; DeskPilot supplies the conflicted text in the prompt and applies the structured result. |
| Binary conflicts | Flagged separately with a per-file keep-ours / keep-theirs choice. |
| Remote-action failure | Keep the successful local merge; report; leave the remote intact; offer retry. |
| Undo | Offer "Undo this merge": reset the Default Branch to its captured pre-merge commit (local only; warned/disabled once pushed). |
| Credentials | Ambient git credential helper / SSH only; DeskPilot stores no git secrets. |

## Non-goals

Rebase, cherry-pick, interactive history editing; creating a GitHub Pull Request;
submodule conflict resolution; merging more than one Branch per run; a custom
merge-commit message editor; the AI using File/Terminal Tools to self-resolve;
merging into any target other than the Default Branch.

## Wizard flow

1. Pick the source Branch (defaults to the current Branch when it is not the
   Default Branch).
2. Preflight: detect a dirty tree / behind-origin and offer the autofix.
3. Preview the incoming commits (capped list).
4. Confirm.
5. Merge (ff-else-merge-commit). On conflict, branch to the Merge Plan sub-flow.
6. Result summary.
7. Cleanup: auto local delete; remote push + delete behind a separate confirm.
8. Optional Undo.

### Merge Plan sub-flow (on conflict)

1. DeskPilot lists conflicted files (`git diff --name-only --diff-filter=U`),
   classifying each as text or binary.
2. For text files, DeskPilot reads the conflicted content and runs a
   pure-reasoning Turn (Tools disabled) asking for a structured per-file
   resolution.
3. The proposed Merge Plan is shown for approval. Nothing is written until the
   user approves.
4. On approval, DeskPilot writes each resolved file, runs `git add`, and commits
   to complete the merge. Binary conflicts are resolved by the user's
   keep-ours / keep-theirs choice (`git checkout --ours/--theirs`).
5. On rejection or AI failure, `git merge --abort` restores the pre-merge tree.

## Implementation map

Backend helpers (each via `Invoke-DpGitCommand`, confined to
`settings.workspaceFolder`, never throwing):

- `Get-DpDefaultBranch` — resolve the Default Branch.
- `Get-DpBranchList` — local + remote-only Branches with a `merged` flag (after an
  optional fetch), the current Branch, and the Default Branch.
- `Invoke-DpGitFetch` — best-effort fetch for badge accuracy.
- `Get-DpMergePreview` — incoming commits + precondition flags (dirty, behind).
- `Invoke-DpGitMerge` — capture the pre-merge sha; optional autofix; merge;
  return success | already-merged | conflict { files } | error.
- `Get-DpMergeConflict` — list + classify conflicted files; read text content.
- `New-DpMergePlanPrompt` / parse — build the conflict prompt and parse the
  structured resolution.
- `Invoke-DpMergeApply` — write resolutions, `git add`, commit.
- `Invoke-DpGitMergeAbort` — `git merge --abort`.
- `Invoke-DpGitMergeUndo` — `git reset --hard <pre-merge-sha>`.
- `Invoke-DpBranchCleanup` — delete local; optional push + delete remote.

Routes (registered in `Start-DeskPilot`, handled in `Invoke-DpRouteHandler`,
behind the session token; `{ error: { code, message } }` on failure):

- `GET  /api/git/branches` — list with merged flags (query `fetch=1` to fetch first).
- `GET  /api/git/merge/preview?branch=` — incoming commits + preconditions.
- `POST /api/git/merge` — `{ branch, autofix? }` -> success | conflict | error.
- `POST /api/git/merge/plan` — conflict files -> proposed resolution (runs a Turn).
- `POST /api/git/merge/apply` — `{ resolutions, binaryChoices }` -> commit.
- `POST /api/git/merge/abort`.
- `POST /api/git/merge/undo` — `{ sha }`.
- `POST /api/git/cleanup` — `{ branch, deleteRemote? }`.

Frontend (`web/`): branch-picker badges (merged checkmark / not-merged
exclamation) with hover tooltips; remote-only entries marked; a "Merge into
main..." action; a multi-step Merge Wizard modal reusing the existing modal
pattern; the conflict sub-flow with plan review and binary choices.

## Failure modes & edge cases

git missing / not a repo -> existing messaging. No remote -> local-only degrade
(hide push/remote-delete; tooltip notes local compare). Fetch fails -> local
compare with a note. Dirty / behind -> autofix offer; pull conflict -> abort +
restore stash. Source == Default Branch -> block. Detached / unborn HEAD -> block
with guidance. Already merged -> skip to cleanup. Huge delta -> cap the commit
list. Can't delete the checked-out Branch -> switch to the Default Branch first.
Remote push/delete failure -> keep local merge; report; retry offered.

## Security

All git via the process-based `Invoke-DpGitCommand` (argument list, no shell),
confined to the selected Project. Branch names validated against the live list.
Remote push/delete are the only networked privileged actions, behind a confirm
distinct from the merge approval, using ambient credentials only. The conflict
Turn runs with Tools disabled. Localhost bind + session token unchanged. This
spec deliberately relaxes the default "never push" stance only through an
explicit per-action user confirm.

## Open questions

- Commit-list cap N (proposed 100).
- Persist the Merge Plan on the Conversation, or keep it ephemeral (proposed
  ephemeral).
- A lightweight merge-history view (proposed: not in v1).