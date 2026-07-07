# Active Context

## Current focus

**Reasoning-effort HTTP 400 on Models without reasoning support — FIXED
(2026-07-07), on `ai/reasoning-effort-model-guard`.**
Reasoning effort is a single global Setting, but support is per-Model:
`claude-haiku-4.5` advertises none, and the Copilot endpoint rejects
`reasoning_effort` for it (`invalid_reasoning_effort`, HTTP 400). `New-DpTurnParameter`
forwarded `-ReasoningEffort` whenever the Setting was truthy regardless of the
effective Model, so a user who had set *max* saw every Turn on such a Model fail
at `EndInvoke` (the reported error). Fix is defence in depth: the effort menu now
offers only the Model's advertised levels, and the Host Server sends the effort to
the Engine only when the effective Model advertises it. Next: fast-forward into
`main` (local-only, not pushed) once reviewed; the Clone Wizard (specs/080)
remains the next feature.

## Just completed (this work, on ai/reasoning-effort-model-guard)

- **State cache** (`Start-DeskPilot`): added `Models` + `DefaultModel` to
  `$script:DeskPilot`; the `/api/models` route (`Invoke-DpRouteHandler`) now
  populates them from the Engine's `Get-ShpModel` capability list.
- **Turn guard** (`New-DpTurnParameter`): new `-ModelReasoningEfforts` param; the
  global reasoning-effort Setting is forwarded as `-ReasoningEffort` only when the
  effective Model advertises the chosen effort (suppressed on empty/unknown, so a
  global preference stays inert on Models that can't honour it — never an HTTP 400).
- **Turn wiring** (`Invoke-DpTurn`): resolves the effective Model (Conversation →
  Settings → Engine default) and passes its cached efforts into the parameter builder.
- **Frontend** (`web/assets/app.js`): the Settings reasoning-effort menu is
  model-aware — options come from the effective Model's `reasoningEfforts` (+
  default), it refreshes when the model changes, and a hint explains when a Model
  supports none or when a saved effort is unavailable for the current Model.
- **Tests:** +5 `New-DpTurnParameter` unit tests (supported→passed; empty→suppressed;
  subset-miss→suppressed; unknown→suppressed; unset→omitted).
- **Specs:** 020 (Turn assembly guard), 030 (models route caches the capability
  list; effort forwarded only when supported), 040 (model-aware effort menu).

Verified: full test suite **258/258, 0 failed** (9 tasks, 0 errors, 0 warnings);
`app.js` parses as a valid ES module (`.mjs` + `node --check`). Root cause matches
the screenshot: `claude-haiku-4.5` + `reasoning_effort "max"` → 400.

## Prior focus — No-project working-directory leak (SHIPPED + MERGED 2026-07-07)

`Invoke-DpTurn` only repositioned the long-lived Engine Runspace when a
`workspaceFolder` was set, so a no-Project Turn ran in whatever directory the
runspace was last left in — the folder DeskPilot was launched from (its own repo
checkout, which has a `.memory-bank/`), or a previously selected Project. New
helper `Get-DpEngineWorkingDir` (Workspace Folder when set, else
`<dataDir>/workspace`); `Invoke-DpTurn` sets the location on every Turn. +3 unit
tests. Fast-forwarded `4dc9e63..0d75a87` into `main` (local-only).

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
