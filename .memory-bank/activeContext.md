# Active Context

## Current focus

**Git for non-experts: Merge Wizard + Clone Wizard.** A grill-me interview on
2026-06-12 produced two signed-off Design Concepts, persisted as
`specs/070-merge-wizard.md` and `specs/080-clone-wizard.md`. Implementation
sequence: the **Merge Wizard first**, then the Clone Wizard.

The Merge Wizard lets a non-expert merge a Branch into the Default Branch (main,
else master) from the existing Git bar: a merged / not-merged badge in the branch
picker, an incoming-commits preview, merge on approval (fast-forward else merge
commit), optional push + remote-branch delete behind a separate confirm,
local-branch cleanup, an AI-proposed Merge Plan on conflict (pure-reasoning Turn,
Tools off; DeskPilot writes the resolved files), and an Undo. Remote actions use
ambient git credentials only.

### Signed-off decisions (interview 2026-06-12)

- Merge target / "merged?" basis: the Default Branch (origin/HEAD, else main, else master).
- Remote scope: local + push main + delete remote, behind a SEPARATE explicit confirm.
- Conflicts: the AI PROPOSES a Merge Plan; the user approves before any write; DeskPilot writes + commits.
- Conflict Turn: pure reasoning, all Tools disabled; binary conflicts get keep-ours / keep-theirs.
- Delta preview: the incoming commit list. Strategy: ff-else-merge-commit.
- Preconditions autofix: stash -> ff main from origin -> merge -> pop; abort safely on a pull conflict.
- Cleanup: auto local delete (after switching to the Default Branch); remote behind a separate confirm.
- Badge: fetch from origin first, then compare; degrade to local-only with no remote / on fetch failure.
- Picker lists local + remote-only Branches; entry point is "Merge into main..." in the Git bar.
- Remote-failure: keep the local merge; report; retry. Undo: reset the default to the pre-merge sha (local only).
- Clone Wizard: one New Project Wizard (clone-vs-local); SSH + ambient credentials only; repo-name default; auto-select.

## Just completed (foundation slice)

- Persisted `specs/070-merge-wizard.md` + `specs/080-clone-wizard.md`.
- Added glossary rows: Branch, Default Branch, Merge, Merge Wizard, Merge Plan, Clone, New Project Wizard (+ boundary notes).
- New Private helpers (process-based, confined, never-throw): `Get-DpDefaultBranch`
  (origin/HEAD -> main -> master), `Invoke-DpGitFetch` (best-effort; reports
  no-remote / offline), `Get-DpBranchList` (local + remote-only Branches with a
  merged-into-Default flag; optional pre-fetch; picks a comparison ref that
  exists locally or as origin/<default>).
- Added 13 unit tests (mock Invoke-DpGitCommand / Get-DpGitStatus / Invoke-DpGitFetch).
  Verified: helpers suite 172/172 green; all new .ps1 parse clean.

## Next steps (Merge Wizard, in order)

1. Backend: `Get-DpMergePreview` (incoming commits + dirty / behind preconditions).
2. Backend: `Invoke-DpGitMerge` (capture pre-merge sha; optional autofix; merge; success | already-merged | conflict { files } | error), `Invoke-DpGitMergeAbort`, `Invoke-DpGitMergeUndo`.
3. Backend: precondition autofix (stash -> ff -> merge -> pop).
4. Backend: `Invoke-DpBranchCleanup` (local delete; optional push + remote delete).
5. Backend: AI Merge Plan -- `Get-DpMergeConflict` (list + classify + read text), build the conflict prompt, run a Tools-off Turn, parse the structured per-file resolution, `Invoke-DpMergeApply` (write + add + commit). Binary: keep-ours / keep-theirs.
6. Routes: register + handlers (`/api/git/branches`, `/merge/preview`, `/merge`, `/merge/plan`, `/merge/apply`, `/merge/abort`, `/merge/undo`, `/cleanup`); update `specs/030-api-contract.md`.
7. Frontend: branch-picker badges (check / exclamation) + tooltips + remote-only; "Merge into main..." entry; the multi-step Merge Wizard modal; the conflict sub-flow.
8. Tests + a guarded real-repo merge test; add the CHANGELOG entry once the UI is reachable.
9. Then: implement the Clone Wizard (spec 080).

## Previous focus (publish/Sampler -- partially shipped)

Phase A (Sampler-ize) and Phase C (CI mirroring ShellPilot, deploy gated OFF) are
DONE. Still pending: Phase B (module-relative `-WebRoot` default, `CopyPaths:
[web]`, manifest metadata, MIT `LICENSE`, built-module smoke) and Phase D
(go-live: pin a stable ShellPilot in RequiredModules, iwr|iex bootstrap, add the
`GalleryApiToken` / `GitHubToken` secrets). See progress.md for the full history.

## Constraints in force

- Localhost-only bind + per-launch session token; single active Turn at a time.
- Filesystem + Git endpoints confined to the selected Project's folder.
- Git runs via `Invoke-DpGitCommand` (process, no shell). Remote push / delete is
  the ONLY networked privileged action and requires a separate explicit
  per-action confirm; ambient git credentials only (DeskPilot stores no secrets).
- Canonical glossary terms only.
- README assets in `assets/`; in-app assets under `web/assets/`.
