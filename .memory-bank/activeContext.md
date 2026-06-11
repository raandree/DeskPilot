# Active Context

## Current focus

**Engine compatibility.** ShellPilot shipped a breaking parameter change to
`Invoke-Shp`: its built-in Task List tool (`manage_todo_list`) is now on by
default and the opt-in `-EnableTodoList` switch was replaced with an opt-out
`-DisableTodoList`. DeskPilot was still passing `-EnableTodoList`, so every Turn
failed against the current Engine. Realigned DeskPilot to the new Engine surface.

## Just completed

- Inverted the Task List mapping in `New-DpTurnParameter`: pass
  `-DisableTodoList` only when the `taskTracking` Setting is **off**; otherwise
  pass nothing and rely on the Engine's default-on behaviour. This preserves
  DeskPilot's previous semantics (Task List on by default) with the new Engine.
- Rewrote the two Task List splat tests (on → asserts no `-DisableTodoList`;
  off → asserts `-DisableTodoList = $true`) and updated the glossary's
  Engine-boundary note (`-EnableTodoList` → `-DisableTodoList`).
- Audited the rest of ShellPilot's recent changes against DeskPilot:
  - `git diff` since ShellPilot's init shows `Invoke-Shp.ps1` as the only
    functional source change, and the Task List rename as its only
    parameter-surface change.
  - The `-ShowThinking` streaming fix needs **no** DeskPilot change — the
    `Get-DpStreamFrame` classifier already handles the trace format (DarkGray
    `thinking:` + ANSI `3;90m` reasoning + DarkCyan/Cyan/Yellow), and the fix
    keeps live streaming on when thinking is enabled (a net improvement).
  - The `ShellPilot.Result` default-view fix is display-only; DeskPilot reads
    result members programmatically, so it is unaffected.
- CHANGELOG `[Unreleased]` and Memory Bank `progress.md` updated.
- Verified: both edited `.ps1` parse clean; Pester **186/186**.

## Next steps

1. Live smoke a streaming + Task List Turn against the updated Engine to confirm
   end-to-end (the unit suite proves the splat; a live run proves the wire).
2. Resume the previous focus (Phase 2.6 QoL batch / regenerate + edit/resend
   live-Engine smoke; brand pass for sub-READMEs — both deferred).

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

