# Active Context

## Current focus

**Expired sign-in left the user stuck (no re-auth path) — FIXED (2026-07-07), on
`ai/stop-button-fix`.**
`authenticated` is derived from the token *file* existing, not its validity, so
an expired token still reported `true`: DeskPilot entered the app (skipping the
sign-in screen), the model list then failed with a 401 from the Engine's token
exchange, and the dropdown dead-ended at "(sign in to load models)" — with the
only re-auth entry point (Settings → Re-authenticate) silently no-op'ing because
a stale token file made both `Invoke-DpAuthFlow` and `Initialize-Shp`
short-circuit. Fix: classify auth failures (`Test-DpAuthError`) so `/api/models`
returns `401 auth_required`; the UI then auto-opens the sign-in overlay in an
"expired" mode that forces a fresh device-code flow (`Initialize-Shp -Force` via
the new `Invoke-DpAuthFlow -Force`). Both this and the Stop-button fix live on
`ai/stop-button-fix`. Next: fast-forward into `main` (local-only, once reviewed);
the Clone Wizard (specs/080) remains the next feature.

## Just completed (this work, on ai/stop-button-fix)

- **New `Test-DpAuthError`** (`source/Private`): classifies a caught error as an
  auth failure by walking the inner-exception chain and matching only auth
  signals (401/403/Unauthorized/Forbidden, "Session token exchange failed",
  "Token file not found", "Initialize-Shp") — so a transient network error is
  never mistaken for an expired sign-in.
- **`/api/models` route**: the catch now returns `401 { code: auth_required;
  reauth: true }` for auth failures (still `502 engine_unavailable` otherwise).
- **`Invoke-DpAuthFlow -Force`**: skips the "already signed in" short-circuit and
  passes `Initialize-Shp -Force`, so an expired token is actually re-issued; the
  `authStart` route forwards `{ force }` from the request body.
- **Frontend** (`web/`): `api()` attaches `status`/`code`/`reauth` to thrown
  errors; `loadModels` opens the re-sign-in overlay on a 401; `showAuth({expired})`
  forces the flow and swaps in "Your sign-in has expired" wording (new
  `#auth-subtitle` in `index.html`); `startAuth` posts `{ force }`; the Settings
  **Re-authenticate** button now forces too.
- **Tests:** +9 `Test-DpAuthError` unit tests (401/403/exchange-failure/missing-
  token/inner-exception/ErrorRecord → true; network + unrelated + null → false).
- **Specs:** 030 (auth/status validity note, auth/start `force` body, models
  `401 auth_required`).

Verified: full test suite **272/272, 0 failed** (16 tasks, 0 errors, 0 warnings);
`app.js` ESM check OK (`node --check` on a `.mjs` copy). Manual smoke recommended:
let a token expire (or corrupt `~/.copilot-demo-token`), open DeskPilot, confirm
the "Your sign-in has expired" overlay appears and Connect runs a fresh device
flow that restores models.

## Also on this branch — conversation menu sizing (FIXED 2026-07-07)

The per-conversation “…” action menu (`popover popover-menu conv-action-menu`) was
hugely oversized: JS positions it with an inline `top`, but it inherited the base
`.popover` `width: min(420px,92vw)` and `bottom: 92px`, so it was ~420px wide and
(top + bottom both set) stretched down the viewport. CSS-only fix on
`.conv-action-menu`: `width: max-content` (+ `min-width:160px`, `max-width`) and
`bottom: auto`. No JS change.

## Prior focus — Stop button did nothing (FIXED 2026-07-07, ai/stop-button-fix)

The single-threaded accept loop handled each request inline, so a running Turn
held the only thread and the Stop button's `POST /stop` waited in the TCP backlog
until the Turn had already finished. `Invoke-DpTurn`'s poll loop now pumps pending
connections each iteration (`Invoke-DpPendingRequest`, sharing the new
`Invoke-DpClient`; `$script:DeskPilot.Listener` registers the `TcpListener`), so a
concurrent `/stop` is serviced mid-Turn and aborts the Engine pipeline. +5 unit
tests. Specs 020/030. Same branch as the sign-in fix above (not yet merged).

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
