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
isolation. The operator approved single-child design V2 in decision 0009. Its
private storage/lifecycle components are implemented, but complete child Engine
integration, approvals, and hard request admission remain open. Decision 0005's
parallel topology is still proposed; no parallel scheduling is enabled.

## Recent milestones

| Date | Milestone |
| --- | --- |
| 2026-09-06 | Operator sign-in restored usable Engine authentication: 43 Models returned. Same-client models control returned 200; Responses input_tokens returned 404, but Claude v1/messages/count_tokens returned 200. Four counter/Engine input pairs were 11/11, 31/31, 587/580, and 669/662; omitting tool_choice did not change counts. Four capped generation requests reported 1,284 input and 19 output tokens, no Tools executed. Authentication is resolved and a hosted count is available; a guaranteed complete-request bound remains unproven. V2, source, Settings, and child readiness are unchanged. Evidence: TEMP/deskpilot-copilot-count-20260906-2121. |
| 2026-09-06 | Investigated the operator's request for live Copilot counting. Public Initialize-Shp returns the named existing credential file, but Get-ShpModel fails during DPAPI decryption before network access (0x8009000B). No credential was exposed or replaced and no Model/count request ran. First-party client counts Tool overhead as an estimate; OpenAI's documented responses/input_tokens operation is a candidate, not verified Copilot support. Resume requires usable Engine authentication; V2 and readiness remain unchanged. |
| 2026-09-06 | Implemented conditional admission in the separate Engine worktree: frozen limits/pricing, request-bound reservations, failed/unknown Usage, and refusal of invalid reports. Engine full gate: 1,810 passed, no failures/skips, 89.12% coverage; DeskPilot: 2,373 passed, five existing skips. Independent review approved the admission diff; its Minor test gap is closed, final focused proof 38 public plus seven helper cases. Operator chose to keep V2 unchanged and close out groundwork: verified provider counting, complete child integration/live proof, and clean-install support remain open. Child startup and parallel scheduling remain unavailable; no push or publication. |
| 2026-09-06 | Retained the eight-commit chain from five local feature Branches for Merge into main. Eleven dirty-file flags were normalization-only; refreshed the index without discarding content. Fresh full Sampler tests: 2,373 passed, zero failures, five existing skips. Node UI tests: 3 passed; desktop/mobile proof passed. Subsequent build: seven tasks, zero errors/warnings; import and 34 bundled asset hashes verified, no child/Terminal containers remain. Child startup and release gates stay closed; no push or remote Branch deletion. |
| 2026-09-06 | Rechecked parallel-Agent prerequisites at DeskPilot 275cd6b and tracked Engine d1e1e13. Fresh approval and child refusal suites: 93 passed, no failures/skips/unrun cases, completed 12:03 UTC. Updated decision 0005 with remaining Engine/profile/public-retrieval dependencies. Independent documentation review approved; its evidence-attribution Nit was corrected. Topology approval is still absent and runtime remains unchanged. |
| 2026-09-06 | Approved single-child V2; implemented private Tool storage, capture, IPC, export, lease, Stop/recovery, retention admission, and an explicit Host Server refusal gate. Final component proof: 87 passed, no failures/skips. DeskPilot full: 2,373 passed, five existing skips. Engine full: 1,749 passed. Review requests changes: one implemented Major corrected with red/green tests; two Major full-profile/admission gates and retention/restart Minor remain. Complete child execution stays blocked. |
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

- Rerun the full live Model/operator acceptance profile. Operator sign-in and
  four capped Engine comparison requests succeeded on 2026-09-06. These counting
  probes resolve the authentication blocker, not the full acceptance profile;
  the earlier `auth_required` result and scripted-provider evidence are historical.
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
