# Active Context

## Current focus

**Engine distribution.** ShellPilot is now published to the PowerShell Gallery,
so DeskPilot no longer relies on a hardcoded local build path. The Engine is
downloaded into the user scope (preview allowed) on first run when it isn't
already available.

## Just completed

- Added `Resolve-DpEngineModule` (new Private helper): resolves the Engine in
  order — explicit `-EngineModulePath`; an already-installed `ShellPilot` on
  `PSModulePath` (newest version); otherwise `Install-Module ShellPilot -Scope
  CurrentUser -AllowPrerelease -Force`, then re-resolve. Returns `{ Path;
  Installed; Error }` and never imports. `-StableOnly` excludes prerelease;
  `-SkipInstall` reports missing instead of installing.
- Rewrote `Initialize-DpEngine` to call the resolver (removed the hardcoded
  `V:/Git/ShellPilot/output/module/ShellPilot` + MyDocuments probes), preserve a
  resolution error through the import fallback, and return an `Installed` flag.
- Surfaced the download in `Start-DeskPilot`'s console output (one-line note when
  `Installed` is true).
- Added 9 unit tests (mock `Get-Module`/`Install-Module`) covering explicit-path,
  already-available, newest-version, install-with-prerelease, `-StableOnly`,
  `-SkipInstall`, install-failure, and installed-but-not-found. Hit a Pester
  gotcha: mocking `Get-Module` before the first `Mock Install-Module` blocks
  PowerShellGet auto-load — fixed by importing PowerShellGet in `BeforeAll`.
- Updated README (prereqs/options), techContext, specs 020/030, and CHANGELOG.
- Verified: both `.ps1` parse clean; Pester **195/195** (+9).

## Next steps

1. Live smoke: launch on a machine without ShellPilot to confirm the Gallery
   download + import + a first Turn end-to-end.
2. Resume the previous focus (Phase 2.6 QoL live-Engine smoke; brand pass for
   sub-READMEs — both deferred).

## Open decisions

- Whether to migrate the in-app web assets to the new `dp-*` naming. Currently
  not — they're wired into the SPA in many places and the brand is identical;
  the docs assets just live alongside under `assets/`.

## Constraints in force

- README assets in `assets/`; in-app assets stay under `web/assets/`.
- Logo variants are transparent (`Format32bppArgb`, corner A=0); judge final
  rendering on github.com (some editor previews mis-resolve
  `prefers-color-scheme`).

## Previous focus (Phase 2.5 + 2.6 QoL batches — shipped)

- **Backend (7 new/edited helpers + 5 routes).** New `Get-DpFileFind`
  (project-confined recursive file search for `#file`), `Get-DpAtelierHealth`
  (per-root resolve/count/junction report), `Get-DpGitDiff` (working-tree diff
  vs HEAD, untracked→content), `Invoke-DpGitRestore` (revert tracked to HEAD +
  delete untracked, path-confined). Edited `New-DpConversation` /
  `Import-DpConversationStore` / `Save-DpConversationStore` (pinned/archived
  fields), `Merge-DpSettings` + `Get-DpDefaultSettings` (preferences, validated,
  8000-char cap), `New-DpTurnParameter` (About-the-user system-prompt block).
  New routes: `GET /api/conversations/search` (registered before `/{id}`),
  `GET /api/fs/find`, `GET /api/git/diff`, `POST /api/git/restore`,
  `GET /api/atelier/health`; `patchConversation` now accepts pinned/archived
  without bumping `updatedUtc`; `listConversations` returns the flags and sorts
  pinned-first.
- **Frontend.** Conversation list rewritten for search results, archived
  hide/show, pinned marker and a per-item ⋯ action menu (pin/archive/rename/
  export); inline Git diff + Undo in the Activity panel; Preferences textarea and
  an auto-loading Atelier health panel in Settings; plus the already-landed
  client-side voice/artifact/insert-menu/drag-drop/explain wiring.
- **Specs + glossary** updated (FR-C10–C14, FR-T6/T7, FR-M7/M8, FR-S4, FR-X6,
  FR-G1; Preferences + Artifact terms; roadmap Phase 2.5 + deferred list).

### Phase 2.6 (second QoL batch)

- **Regenerate** the last response (`POST /regenerate`) and **edit & resend** a
  user Message (`POST /edit`), both via `Reset-DpConversationForRerun` (truncate
  to a user Message, rebuild Engine history, re-run `Invoke-DpTurn`). The `start`
  SSE frame now also carries `userMessageId` so the optimistic user bubble gets
  an authoritative id for in-place edit.
- **Command palette** (Ctrl/Cmd+K) + shortcuts (Ctrl/Cmd+Shift+O new, `/` focus).
- **Reference files** Setting injected into the Turn system prompt (paths, not
  contents — build-free light retrieval).
- **Spend warning** Setting (`costBudgetUSD`) — one-time session-cost toast.
- Verified: 186/186 Pester (+11), 7/7 round-2 endpoint smoke, `node --check`
  clean, PSScriptAnalyzer baseline-consistent (only the accepted
  `PSUseShouldProcessForStateChangingFunctions` on `Reset-Dp…`, as on existing
  `Update-DpUsage`/`Set-DpEngineLocation`).

## Open decisions (carried over)

- **Undo semantics.** "Undo a Turn" reverts to the last **commit**, not a
  pre-Turn snapshot (DeskPilot keeps no snapshot). Documented in the UI confirm;
  committing before a Turn makes undo exact. Revisit if per-Turn snapshots are
  wanted.
- **Artifacts.** Only `html`/`svg` render (sandboxed); Mermaid/charts are
  deferred (need a JS lib/CDN, against build-free + offline).
- **RAG / scheduled prompts / MCP / multi-model compare** deliberately deferred
  (see roadmap “Deliberately deferred”) — constraint- or Engine-bound.

## Engine-side constraints (carried over)

- Localhost-only bind + per-launch session token.
- Single active Turn at a time.
- Filesystem + Git endpoints are confined to the selected Project's folder; the
  Customization endpoints to a configured root + the category's file pattern.
- Artifact frames run sandboxed (`allow-scripts`, no `allow-same-origin`) under a
  strict CSP: no network, cookies, storage, or access to DeskPilot.
- Canonical glossary terms only (Preferences, Artifact included).

