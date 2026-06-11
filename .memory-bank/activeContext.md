# Active Context

## Current focus

Shipped a **knowledge-worker quality-of-life batch** (Phase 2.5) on top of the
Customizations surface and logo work: conversation **search**, **pin/archive**,
and Markdown **export**; **voice** (dictation + read-aloud) and per-message
copy; **artifact preview** (sandboxed `html`/`svg`); a composer **Insert menu**
(`/` prompt files, `#` project files); **drag-and-drop** attachments; **Explain
this Customization**; durable user **Preferences** injected into every Turn;
Git-based **undo a Turn's file changes** + inline **diff**; and an **Atelier
health** panel. All verified: 175/175 Pester, 11/11 live HTTP endpoint smoke,
`node --check` clean, every `.ps1` parses.

## Just completed

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

## Next steps

1. Optional real-Engine streaming check of regenerate/edit (consumes credits;
   the Reset helper is unit-tested and the routes reuse the live-verified
   `Invoke-DpTurn` path).
2. Consider per-Conversation reference files / preferences (today both are global
   Settings).

## Recently added (Phase 2.6, second QoL batch)

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

## Open decisions

- **Undo semantics.** "Undo a Turn" reverts to the last **commit**, not a
  pre-Turn snapshot (DeskPilot keeps no snapshot). Documented in the UI confirm;
  committing before a Turn makes undo exact. Revisit if per-Turn snapshots are
  wanted.
- **Artifacts.** Only `html`/`svg` render (sandboxed); Mermaid/charts are
  deferred (need a JS lib/CDN, against build-free + offline).
- **RAG / scheduled prompts / MCP / multi-model compare** deliberately deferred
  (see roadmap “Deliberately deferred”) — constraint- or Engine-bound.

## Constraints in force

- Localhost-only bind + per-launch session token.
- Single active Turn at a time.
- Filesystem + Git endpoints are confined to the selected Project's folder; the
  Customization endpoints to a configured root + the category's file pattern.
- Artifact frames run sandboxed (`allow-scripts`, no `allow-same-origin`) under a
  strict CSP: no network, cookies, storage, or access to DeskPilot.
- Canonical glossary terms only (Preferences, Artifact included).

