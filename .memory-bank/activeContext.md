# Active Context

## Current focus

**Automatic conversation titles (like GitHub Copilot) — SHIPPED on
`ai/auto-conversation-title` (2026-07-07), local-only, not yet merged.**
Previously a brand-new Conversation was titled with a crude 60-char truncation of
the first prompt (inline in `Invoke-DpTurn`). Now, after the first Turn, the SPA
fires a new best-effort `POST /api/conversations/{id}/title`; the Host Server runs
a pure-reasoning Turn with **all Tools disabled** (the Merge-Plan pattern via
`Invoke-DpEngineCommand`) to summarise the first prompt into a few words, cleans
it, and persists it — the sidebar + title field update in place.

Design (mirrors `New-DpMergePlanPrompt` / `ConvertFrom-DpMergePlan`):

- **`New-DpTitlePrompt`** (pure): a strict "few-word title only, no quotes/
  punctuation/Markdown" instruction; the input prompt is truncated to 800 chars.
- **`ConvertFrom-DpTitleResult`** (pure): first meaningful line (skips a leading
  `label:` line + code fences), strips a `Title:` label / Markdown heading-list
  markers / surrounding straight+smart quotes+backticks, collapses whitespace,
  removes trailing punctuation, caps words (8) then length (60, `…`). Returns ''
  when nothing usable → caller keeps the fallback title.
- **Route `titleConversation`**: returns the current title unchanged when
  `titleLocked` or past the first exchange (>1 user Message); `409` if a Turn is
  running; else Engine call (Tools off) + clean + persist. Never throws.
- **`titleLocked`** — a new Conversation field (default `$false`), set `$true` on a
  manual rename in `patchConversation`, persisted through `New-DpConversation` /
  `Import-DpConversationStore` / `Save-DpConversationStore` (the store whitelists
  fields). Auto-titling never clobbers a user's chosen name.
- **Frontend `maybeAutoTitle()`** in `_runTurn`'s `finally` (after the composer
  re-enables), gated to `messageCount <= 2`; the server makes the final call.
  Single-threaded server ⇒ no runspace race (a user send during title-gen queues).

The instant truncation in `Invoke-DpTurn` stays as the fallback shown until the AI
title arrives (and if titling is skipped/fails). +17 unit tests. Verified: full
suite **299/299, 0 failed** (9 tasks, 0 errors, 0 warnings); `app.js` ESM check OK
(`.mjs`). Specs 030 + CHANGELOG updated.

## Next steps

1. **Manual browser smoke of auto-titles:** start a new Conversation, send a first
   message, confirm the sidebar title flips from the truncated prompt to a concise
   AI summary a moment after the reply; rename it, then edit the first prompt and
   confirm the manual name is NOT overwritten (`titleLocked`). Merge
   `ai/auto-conversation-title` into `main` (local-only) when satisfied.
2. **Live HTTP smoke of the merge routes** (before merging the Merge Wizard to
   main): exercise /api/git/branches, /merge/preview, a real merge, a conflict →
   /merge/plan → /merge/apply, and /cleanup (local-only; the plan route needs the
   Engine authenticated).
3. **Manual browser smoke** of the Merge Wizard (badges, tooltips, each step).
4. **Clone Wizard (spec 080):** one New Project Wizard (clone-vs-local first
   screen); `Invoke-DpGitClone`; `POST /api/projects/clone`; reuse the folder
   picker; SSH + ambient credentials only; auto-select the new Project.
5. Then resume the parked publish/Sampler work (Phase B/D) if desired.

## Prior focus — "Working…" spinner froze under reduce-motion (FIXED + MERGED 2026-07-07)

The streaming donut sat frozen for users with OS animations off (a blanket
`@media (prefers-reduced-motion: reduce) { * { animation: none } }` in
`styles.css` killed its rotation). CSS-only fix: a targeted `.spinner` override
keeps it smoothly rotating (`spin 1s linear infinite`) under reduced motion, plus
a legibility bump. Fast-forwarded `0667920..4896066` into `main` (local-only);
`ai/working-spinner-motion` kept.

## Prior focus — Transient 403 on the Copilot session-token exchange (FIXED + MERGED 2026-07-07)

**Transient 403 on the Copilot session-token exchange failed the whole Turn —
FIXED + MERGED to `main` (2026-07-07).**
ShellPilot exchanges the cached GitHub token for a short-lived Copilot session
token at the start of every Turn; that endpoint intermittently returns 403
(Forbidden), so `Invoke-Shp` threw, `EndInvoke` rethrew, and the Turn failed with
a raw *"Session token exchange failed … 403"* — the user had to stop and resend
(which worked, because a retry of the exchange succeeds). Fix: a bounded retry of
the Engine call in `Invoke-DpTurn` for transient PRE-STREAM failures, so these
blips are invisible. All four fixes from `ai/stop-button-fix` are now
fast-forwarded into `main` (`ac71cec..c89c0c7`, local-only, not pushed); the
Clone Wizard (specs/080) is the next feature.

## Just completed (this work, on ai/stop-button-fix)

- **New `Test-DpTransientEngineError`** (`source/Private`): flags transient Engine
  failures worth retrying (403/408/429/5xx, forbidden, timeouts, dropped
  connections, unable-to-connect) by walking the inner-exception chain —
  deliberately NOT 401/Unauthorized, so a genuine expired sign-in is surfaced for
  re-auth, never retried.
- **`Invoke-DpTurn` retry**: the Engine invocation now runs in a bounded loop
  (max 3 attempts, 400 ms × attempt back-off). It retries ONLY when the failure is
  transient AND nothing has streamed yet (`$turnState.emitted -eq 0`, a new frame
  counter incremented in `$emit`), so answer text is never duplicated; a Stop
  during a back-off ends the Turn cleanly.
- **Tests:** +10 `Test-DpTransientEngineError` unit tests (403/429/503/timeout/
  dropped-connection/inner-exception → true; 401 + missing-token + unrelated +
  null → false).

Verified: full test suite **282/282, 0 failed** (16 tasks, 0 errors, 0 warnings).
Manual smoke: reproduce a 403 (or hit the flaky endpoint) and confirm the Turn now
streams normally instead of failing — no stop-and-resend needed.

## Recently on this branch — expired sign-in re-auth (FIXED 2026-07-07)

`authenticated` reflected the token *file* existing, not its validity, so an
expired token dead-ended at "(sign in to load models)". Now `/api/models` returns
`401 auth_required` (`Test-DpAuthError`) and the UI auto-opens the sign-in overlay
in an "expired" mode that forces a fresh device flow (`Invoke-DpAuthFlow -Force`
→ `Initialize-Shp -Force`). +9 unit tests. Specs 030.

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
