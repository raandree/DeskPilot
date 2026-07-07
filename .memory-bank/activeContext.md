# Active Context

## Current focus

**No-project working-directory leak — FIXED and MERGED to `main` (2026-07-07).**
`Invoke-DpTurn` only repositioned the long-lived Engine Runspace when a
`workspaceFolder` was set, so a no-Project Turn ran in whatever directory the
runspace was last left in — the folder DeskPilot was launched from (its own repo
checkout, which has a `.memory-bank/`), or a previously selected Project. An
agent that follows a pre-flight/memory-bank convention therefore probed
`Test-Path .memory-bank` and read DeskPilot's own Memory Bank even though the
user had no Project selected — exactly the confusing behaviour the user reported.
Fix: point the Engine at a deterministic working directory on every Turn.
Fast-forwarded `4dc9e63..0d75a87` into `main` (local-only, not pushed). Next: the
Clone Wizard (specs/080) is the next feature.

## Just completed (this work, on ai/no-project-cwd-leak)

- **New helper** `Get-DpEngineWorkingDir` (source/Private): resolves the Engine's
  per-Turn working directory — the Workspace Folder when set, else
  `<dataDir>/workspace` (via `Get-DpDataDir`). Path-only; mirrors `Get-DpUploadDir`.
- **Backend** `Invoke-DpTurn`: replaced the `if ($settings.workspaceFolder)` guard
  around `Set-DpEngineLocation` with an unconditional call through
  `Get-DpEngineWorkingDir`, so the runspace `$PWD` + `[Environment]::CurrentDirectory`
  are deterministic every Turn (no launch-dir or stale-Project leak).
- **Tests:** +3 `Get-DpEngineWorkingDir` unit tests (workspace passthrough;
  fallback on null; fallback on whitespace — `Get-DpDataDir` mocked).
- **Specs:** 020-architecture (Turn now sets a neutral cwd when no Project) and
  050-security-model (no-Project cwd is a neutral scratch folder, not the launch
  dir — a confinement note).

Verified: Unit suite **241/241, 0 failed** (the 3 new tests pass); language-service
clean on the new helper + edited `Invoke-DpTurn` (the pre-existing `$routes`
unused-var warning at test line 71 is untouched). Root cause confirmed: DeskPilot's
own `.memory-bank/` holds `projectbrief.md`/`productContext.md`/`activeContext.md`
— the exact files the in-app agent reported reading.

## Prior focus — Attach without a Project (SHIPPED 2026-07-07)

Removed the last place that forced a selected Project (attaching a file): uploads
fall back to `<dataDir>/uploads` via the new `Get-DpUploadDir` when no Project is
active. Backend `Invoke-DpRouteHandler` dropped its `no_workspace` guard; the
frontend passes absolute upload paths when there is no Workspace Folder. +3
`Get-DpUploadDir` tests. Fast-forwarded into `main` (`596da8b..e313da7`).

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
