# Active Context

## Current focus

**Attach without a Project — SHIPPED (2026-07-07), now on `main`.** Removed the last place that
still forced a selected Project: attaching a file. The composer's Attach button
(and drag-and-drop) previously toasted "Select or register a project before
attaching files." and refused to upload when no Workspace Folder was active —
which contradicted the just-shipped Close Project feature (no-project is now a
legitimate state). Uploads now fall back to `<dataDir>/uploads` when no Project
is selected. Fast-forwarded into `main` (`596da8b..e313da7`); `main` is local-only,
ahead of `origin/main` by 2 commits (Close Project + this), not pushed. The next
substantive feature remains the **Clone Wizard** (specs/080), then a live HTTP
smoke of the merge routes.

## Just completed (this work, on ai/attach-without-project)

- **New helper** `Get-DpUploadDir` (source/Private): resolves the upload target
  directory — the Workspace Folder when set, else `<dataDir>/uploads` (via
  `Get-DpDataDir`). Path-only; the caller creates the directory.
- **Backend** `Invoke-DpRouteHandler` (`uploads` route): dropped the
  `no_workspace` 400 guard; the target dir now comes from `Get-DpUploadDir`. The
  existing `Test-Path`/`New-Item` block creates `<dataDir>/uploads` on first use.
- **Frontend** `web/assets/app.js`: removed the no-project guard in
  `uploadFiles`; the send-time attachment note now names the uploads' **absolute
  paths** when there is no Workspace Folder (the agent's cwd is not the upload
  dir), and keeps the relative-names-in-the-Workspace-Folder phrasing when a
  Project is active.
- **Tests:** +3 `Get-DpUploadDir` unit tests (workspace passthrough; fallback on
  null; fallback on whitespace — `Get-DpDataDir` mocked).
- **Specs:** FR-C9 (010), File uploads (020), Uploads (030 — no longer 400 on no
  Workspace Folder), composer Attach copy (040).

Verified: Unit suite **240/240, 0 failed** (the 3 new tests pass); `app.js` ESM
check OK (`.mjs` copy = the browser's module parser); PSScriptAnalyzer clean on
the new helper + edited handler region; edited files clean in the language
service (the pre-existing `$routes` unused-var warning at test line 71 is
untouched, not from this change).

## Prior focus — Close Project (SHIPPED 2026-07-07)

Added a way to close (deselect) the active Project so DeskPilot returns to a
no-project state; previously you could only switch Projects or create a new one.
UI + specs only — the backend already supported a null `selectedProjectId`
(deriving a null `workspaceFolder`). New `closeProject()` (= `selectProject(null)`);
a **Close project** entry in the composer project popover (shown only when a
Project is active); a **Close** button on the selected row of the Settings
Projects manager. +1 `Merge-DpSettings` regression (close clears selection +
`workspaceFolder`, keeps the Project registered — distinct from removal).


## Prior focus — Branch Merge Wizard (SHIPPED 2026-06-12)

The Merge Wizard lets a non-expert merge a Branch into the Default Branch (main,
else master) from the explorer Git bar (per-branch merged/not-merged badges +
legend; a "Merge into <default>…" step wizard; an AI-proposed Merge Plan on
conflict, approved before any write; local cleanup; remote push+delete behind a
SEPARATE confirm; Undo). Backend + 8 routes + UI on `ai/merge-wizard`
(50b4ca5 foundation, c84f628 backend, 0612594 routes+UI). Remaining for that
track: a live HTTP smoke of the merge routes.

## Next steps

1. **Live HTTP smoke of the merge routes** (recommended before merge to main):
   start Start-DeskPilot with a real-repo Project, exercise /api/git/branches,
   /merge/preview, a real merge, a conflict -> /merge/plan -> /merge/apply, and
   /cleanup (local-only). The plan route needs the Engine authenticated. Helpers
   are already real-repo-tested; this validates the HTTP + UI wiring.
2. **Manual browser smoke** of the wizard (badges render, tooltips, each step).
3. **Clone Wizard (spec 080):** one New Project Wizard (clone-vs-local first
   screen); Invoke-DpGitClone (validate URL, derive repo basename, clone via
   Invoke-DpGitCommand, never-throw); POST /api/projects/clone; reuse the folder
   picker; SSH + ambient credentials only; auto-select the new Project.
4. Then resume the parked publish/Sampler work (Phase B/D) if desired.

## Design decisions in force (Merge Wizard, signed off 2026-06-12)

- Merge target / "merged?" basis = the Default Branch (origin/HEAD, else main, else master).
- Conflicts: AI PROPOSES a Merge Plan (pure-reasoning Turn, Tools off); user approves; DeskPilot writes+commits. Binary = keep-ours/theirs.
- Strategy ff-else-merge-commit; autofix stash->ff->merge->pop; abort safely on a pull conflict.
- Cleanup auto local delete; remote push+delete behind a SEPARATE explicit confirm; ambient git credentials only.
- Badge fetches from origin first in the wizard (accuracy); the Git bar uses no-fetch (speed). Remote-failure keeps the local merge. Undo resets the default to the pre-merge sha (local only).

## Constraints in force

- Localhost-only bind + per-launch session token; single active Turn at a time
  (the merge/plan route guards on $state.TurnRunning, returns 409 if busy).
- Filesystem + Git endpoints confined to the selected Project's folder; git runs
  via Invoke-DpGitCommand (process, no shell). Remote push/delete is the only
  networked privileged action and requires a separate explicit per-action confirm.
- Canonical glossary terms only. README assets in assets/; in-app under web/assets/.

## Previous focus (publish/Sampler -- partially shipped)

Phase A (Sampler-ize) + Phase C (CI mirroring ShellPilot, deploy gated OFF) DONE.
Pending: Phase B (module-relative -WebRoot default, CopyPaths [web], manifest
metadata, MIT LICENSE, built-module smoke) and Phase D (go-live: pin stable
ShellPilot, iwr|iex bootstrap, add GalleryApiToken/GitHubToken secrets).
