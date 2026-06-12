# Active Context

## Current focus

**Publish/Sampler decision — signed off 2026-06-12.** A grill-me interview
concluded: **convert DeskPilot to a Lean Sampler project now**, and make it
**publish-ready now but publish-for-real later** (deferred until a stable,
non-prerelease ShellPilot exists or a first user appears). Phased plan A–D:

- **A — Sampler-ize (no publish): DONE (2026-06-12).** Source moved
  `src/DeskPilot/` → `source/` (empty psm1 + `Prefix.ps1` carrying StrictMode);
  manifest version → `0.0.1` placeholder (GitVersion owns it). Lean scaffolding
  (`build.yaml`, `RequiredModules.psd1` incl. ModuleBuilder's `Configuration`/
  `Metadata` deps, `GitVersion.yml` with `main` as mainline, plus `build.ps1`/
  `Resolve-Dependency.*` copied from ShellPilot). Tests split into `tests/QA` +
  `tests/Unit` (QA per-function gates scoped to the **exported** surface, since
  DeskPilot has one public command + ~60 collectively-tested Private helpers).
  `./build.ps1` green: build 0 errors, **207 tests pass / 0 failed**.
- **B — Make installable:** module-relative `-WebRoot` default (currently
  `[Parameter(Mandatory)]`); ModuleBuilder `CopyPaths` to bundle `web/`; remove
  hardcoded `0.1.0` (GitVersion owns it); fix manifest metadata
  (ProjectUri→raandree/DeskPilot, real Author, IconUri, fuller description); add
  `LICENSE` (MIT); built-module smoke test.
- **C — CI (dry-run): pipeline added 2026-06-12 (`.github/workflows/ci.yml`).**
  Mirrors ShellPilot: build (GitVersion + pack + artifact) -> test matrix
  (ubuntu/windows/macos, PS7) -> smoke (import the built module, assert
  `Start-DeskPilot` exported) -> deploy. Deploy is **gated OFF** behind the repo
  variable `PUBLISH_ENABLED == 'true'` (plus owner + main/tag) until go-live.
  Smoke is import-only for now; the full server `/api/health` smoke waits for
  Phase B (web bundled + module-relative `-WebRoot`). Still to configure in the
  GitHub UI (not code): branch protection (PR-only + green-CI-to-merge) and the
  `PUBLISH_ENABLED` variable + `GitHubToken`/`GalleryApiToken` secrets at go-live.
- **D — Go-live (later, separate decision):** stable ShellPilot →
  `RequiredModules` pin (min tested version) → cross-platform `iwr|iex`
  bootstrap (in-repo, HTTPS, tag-pinned; CurrentUser + trust PSGallery + TLS 1.2
  + PS7 check) → enable the publish gate.

**Previous focus (Engine distribution — shipped).** ShellPilot is published to
the PowerShell Gallery; DeskPilot downloads it into the user scope (preview
allowed) on first run via `Resolve-DpEngineModule` when not already available.
Phase D's `RequiredModules` pin will supersede this.

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

1. **Phase B — make installable** (next): give `Start-DeskPilot` a module-relative
   `-WebRoot` default; move `web/` under `source/` + set `CopyPaths: [web]` so the
   SPA ships inside the built module; remove the remaining hardcoded `0.1.0` in
   `$script:DeskPilot.Version`; fix manifest metadata (ProjectUri →
   raandree/DeskPilot, real Author, IconUri, fuller description); add `LICENSE`
   (MIT); extend the CI smoke to start the Host Server and GET `/api/health`.
   Also repoint the root `Start-DeskPilot.ps1` launcher's `WebRoot` (currently
   `$repoRoot/web`) once `web/` moves to `source/web` — or drop `-WebRoot` there
   and rely on the new module-relative default. The root launcher + `DeskPilot.cmd`
   stay as the dev/clone convenience (never shipped to the Gallery).
2. **Phase C remainder (GitHub UI, not code):** enable branch protection on `main`
   (PR-only + require the CI checks) once the workflow has run on a PR; leave
   `PUBLISH_ENABLED` unset until go-live.
3. Before C/D: confirm a stable (non-prerelease) ShellPilot release and pick the
   minimum version to pin; confirm the mirrored secret names
   (`GitHubToken`/`GalleryApiToken`) match ShellPilot (Decision Concept TBDs
   #1–#3).
4. Optionally persist the signed-off Decision Concept as `specs/070-*.md`.
5. Carried over: live smoke (launcher first-run build + a Turn end-to-end).

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

