# Active Context

## Current focus

**Stop button did nothing — FIXED (2026-07-07), on `ai/stop-button-fix`.**
The Host Server's accept loop is single-threaded and handles each request
inline, so a running Turn held the only thread for its whole duration. The Stop
button's `POST /stop` therefore sat unaccepted in the TCP backlog until the Turn
had already finished on its own, so the `CancelRequested` flag (which the Turn
loop checks to call `[PowerShell].Stop()`) was set far too late — the button
appeared dead. Fix: the Turn's poll loop now pumps pending HTTP connections each
iteration, so a concurrent `/stop` is serviced mid-Turn and the next iteration
aborts the Engine pipeline. Next: fast-forward into `main` (local-only, once
reviewed); the Clone Wizard (specs/080) remains the next feature.

## Just completed (this work, on ai/stop-button-fix)

- **New `Invoke-DpClient`** (`source/Private`): extracted the accept loop's
  per-client read → dispatch (`Invoke-DpRequest`) → close, with a `-ReadTimeoutMs`
  param. Shared by `Start-DeskPilot` and the pump; swallows all errors so one bad
  connection never tears down the server or an in-flight Turn.
- **New `Invoke-DpPendingRequest`** (`source/Private`): the request pump. While
  the registered `$script:DeskPilot.Listener` has `Pending()` connections (capped
  at 16/call, 5s read timeout) it accepts and dispatches each via `Invoke-DpClient`.
  No-ops when no listener is registered (unit tests / safety).
- **`Start-DeskPilot`**: registers the `TcpListener` on
  `$script:DeskPilot.Listener` (new field), replaced the inline accept-loop client
  handling with `Invoke-DpClient`, and clears the listener on shutdown.
- **`Invoke-DpTurn`**: the poll loop now calls `Invoke-DpPendingRequest` right
  before the `CancelRequested` check, so a mid-Turn `/stop` flips the flag and is
  observed on the same iteration (`$shell.Stop()` → `error` frame `Turn stopped.`).
- **Tests:** +5 `Invoke-DpPendingRequest` unit tests (no state → no-op; no
  listener → no-op; empty backlog → 0 accepts; drains a 3-deep backlog; caps at
  MaxRequests). The fake listener returns unconnected `TcpClient`s so no socket I/O.
- **Specs:** 020 (cancellation-on-a-single-thread note in Streaming design + the
  single-threaded accept-loop bullet), 030 (stop serviced mid-Turn).

Verified: full test suite **263/263, 0 failed** (16 tasks, 0 errors, 0 warnings).
Root cause is architectural: a single-threaded inline accept loop + a
long-running Turn = no thread free to accept the stop request until the Turn ends.

## Prior focus — Reasoning-effort HTTP 400 (SHIPPED + MERGED 2026-07-07)

Reasoning effort is a single global Setting, but support is per-Model
(`claude-haiku-4.5` advertises none → Copilot rejects `reasoning_effort` with
HTTP 400). Fix (defence in depth): the Host Server caches the `/api/models`
capability list; `New-DpTurnParameter` forwards `-ReasoningEffort` only when the
effective Model advertises the chosen effort; the Settings effort menu is
model-aware. +5 unit tests. Fast-forwarded `a1df360..9c3c3e8` into `main`.

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
