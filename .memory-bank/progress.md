---
schema-version: 1
status: accepted
owner: shared
last-verified: 2026-09-06
source: repository history, verification, and operator review confirmation
---

# Progress

## Current status

DeskPilot has a local Host Server, build-free UI, persisted Conversations and
Settings, Engine integration, visible Permissions/Activity/Usage, pending changes
and Undo, Diagnostics, Intercom, scheduling, and contained browser automation.
Optional Terminal isolation has completed local design, implementation, review,
and documentation. Live authenticated acceptance and clean-install Engine
availability remain release follow-ups; nothing has been published.

Parallel Agents remain blocked: Terminal containment is not child Agent
isolation. Decision 0005 now records the current evidence and proposed topology,
quotas, security boundaries, recovery, and dependencies; runtime work is not
authorized until the prerequisites and operator approval are complete.

## Recent milestones

| Date | Milestone |
| --- | --- |
| 2026-09-06 | Added a new-chat single-child isolation Prompt File and routed it before parallel Agents. It targets the missing complete Tool boundary and quota-backed storage after design approval; no runtime implementation or topology approval occurred. Added three conversation-based prompt acceptance cases; behavioral evaluation remains unrun. |
| 2026-09-06 | Reassessed Parallel Agents and retained the prerequisite stop. Corrected stale isolation/batch claims and recorded a proposed complete child boundary and dependency plan. Existing Terminal approval suite: 65 passed, zero failures/skips, Pester 5.7.1 with staged ShellPilot 0.4.1; no runtime changes. |
| 2026-09-06 | Closed the final technical-writer stage after the operator confirmed the review passed. Documented visible mode changes, migration, return to Local, and removal; refined Unreleased notes. Source/tests/build still match f6af6fd. Markdown rendering and local links pass; prior executable evidence is retained, not rerun. |
| 2026-09-05 | Implemented optional Local/Isolated Terminal execution on Docker Desktop/WSL2, retaining working nonempty HTTPS allow-lists. Local stays default; no silent fallback. |
| 2026-09-05 | Full final Sampler gate: 2286 passed, 0 failed, 5 unchanged browser Unicode skips; 16 tasks, zero errors/warnings. Real-container isolation suite: 29/29, no skips. |
| 2026-09-05 | Independent review found one Major protocol gap, reproduced by HTTP-over-443 and non-CONNECT HTTPS. Explicit encrypted HTTPS/CONNECT gates fixed it; four protocol checks pass. |
| 2026-09-05 | Full deterministic HTTP approval/execution/Activity/Usage-mapping/pending-change/Undo workflow passed. Undo preserved a pre-Turn user edit. Desktop/mobile and early-open UI checks passed. |
| 2026-09-05 | HTTP acceptance exposed StrictMode state initialization and nested pending-change arrays. Regression tests preceded their fixes; the complete HTTP workflow now passes. |
| 2026-09-05 | Installed and verified Docker Desktop/WSL2. Earlier junction proof established that host-drive aliases must remain absent; whole-drive sharing is not itself a Project boundary. |
| 2026-09-05 | Contained browser automation completed with per-Project writes, individual approvals, Diagnostics lifecycle, mutation guards, hostile-site and live-workflow evidence. |
| 2026-09-03 | Enforced disabled built-in Tool dispatch upstream in ShellPilot and renamed DeskPilot's owned Terminal Tool to avoid built-in shadowing. |
| 2026-09-03 | Added safe-mode file-triggered work on the existing scheduled single-Turn dispatcher; retained stronger gates for unattended Terminal authority. |

## Open release work

- Reauthenticate Copilot and rerun the live Model/operator acceptance profile.
  The attempted live run returned `auth_required`; scripted-provider acceptance
  is labeled and does not establish live billing or authentication success.
- Make a dispatch-enforcing Engine obtainable for clean installations. Staged
  ShellPilot 0.4.1 passes; installed 0.4.0 fails closed. No publication is
  authorized by the current request.
- Changes are recorded on the local topic branch; no push or publication.

## Stable boundaries

- The Engine remains responsible for provider calls, Models, authentication and
  Usage; DeskPilot orchestrates rather than replaces it.
- Category Permissions and individual approvals are distinct from containment.
- Terminal isolation does not isolate File, Browsing, MCP or Intercom.
- Read-write Project mounts have no total disk quota. Concurrent outside edits
  and Git-ignored files retain documented change-accounting/Undo limitations.
- Runtime preparation and cleanup require explicit user actions; a Turn never
  installs dependencies or widens its execution boundary.

## Historical records

The previous progress file, including its complete milestone table, decision
log, prior browser review rounds and earlier work, is preserved byte-for-byte in
[progress-2026-09-05.md](archive/progress-2026-09-05.md). It is historical evidence,
not current source authority. Consult the changelog and Git history for releases.
