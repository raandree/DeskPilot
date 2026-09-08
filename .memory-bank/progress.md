---
schema-version: 1
status: accepted
owner: shared
last-verified: 2026-09-08
source: full Sampler gates, Intercom regressions, and built-preview browser proof
---

# Progress

## Current status

DeskPilot has a local Host Server, build-free UI, persisted Conversations and
Settings, Engine integration, visible Permissions/Activity/Usage, pending changes
and Undo, Diagnostics, Intercom, scheduling, and contained browser automation.
Optional Terminal isolation has completed local design, implementation, review,
and documentation. Live authenticated acceptance and clean-install Engine
availability remain follow-ups. Preview `0.5.0-preview0021` is published on
GitHub and PowerShell Gallery after the successful hosted CI repair run.

Parallel Agents remain blocked: Terminal containment is not child Agent
isolation. The approved single-child V3 now provides complete confined execution,
approvals, bounded provider attempts/bytes, explicit estimated budgets, and
verified lifecycle. Its local prepared preview is proven but disabled. Strict
V2 still requires its unavailable verified provider counter. Decision 0005's
parallel topology remains proposed; no parallel scheduling is enabled.

## Recent milestones

| Date | Milestone |
| --- | --- |
| 2026-09-08 | On explicit user request, fast-forward `main` from `912b158` to `07b57eb` and push to `origin/main`. Hosted CI run `34214508250` passed all five jobs. Pester 6.1.0: Windows 2,492 passed/13 skipped; macOS and Ubuntu each 2,450 passed/55 skipped; zero failures. Deployment completed at 10:20:46 UTC and published Preview `0.5.0-preview0021` to GitHub and PowerShell Gallery, independently verified through public metadata. Monitoring stopped. The final Memory Bank record is documentation-only with `[skip ci]`; no further application or build changes. |
| 2026-09-08 | Honor the user's Pester 6 policy: restore `Pester = 'latest'` instead of the 5.7.1 pin and update contributor guidance. Clean full Sampler gates using Pester 6.1.0 pass on Windows (2,492 passed, 13 skips) and Linux (2,448 passed, 57 skips), zero failures and 17 tasks without errors/warnings on each. Windows dependency resolution passes. Existing tests need no further rewrites; counts/skips match the earlier baseline. An initial Linux harness missing Node.js was corrected without repository changes. Hosted/macOS verification and any push remain user-controlled. |
| 2026-09-08 | Monitor the user's pushed `912b158`: CI run `34209511633` packaged successfully but failed all three test jobs. Repair Pester version drift, Sampler QA/Unit selection, Windows-only child test expectations, duplicate IPC type compilation, and a thread-pool-dependent Stop probe. Restore Unix Support bundle exports without relaxing protections. Artifact-based Linux full gate: 2,448 passed, zero failed, 57 platform skips; final Windows test workflow: 2,492 passed, zero failed, 13 skips. All 29 JavaScript tests pass on each platform. Repairs remain local on `ai/ci-test-repair`; hosted/macOS recheck requires an authorized push. |
| 2026-09-08 | Add Terminal Amber and Terminal Green with a local 3270 web font and independent Theme/Mode selectors. All 16 new theme cases passed red/green; 29 native UI tests pass. Real-frontend desktop/mobile fixture checks verify palettes, contrast, fonts, persistence, translated labels, and unclipped controls. Full Sampler gate: 2,551 passed, zero failures, 18 skips, 17 tasks without errors/warnings. Built asset hashes and real preview HTTP checks pass. Font research and licence are recorded. User requested no commit; changes remain uncommitted on `ai/terminal-themes`, with no push or publication. |
| 2026-09-08 | Close FIND-011/FIND-012: an exact same-group pending-question text reply now bypasses the mention requirement, with no exception for other work. Update specification 110, the guide, and Unreleased wording. Two acceptance cases passed red/green; all 209 Intercom tests pass. Final full gate: 2,551 passed, zero failures, 18 skips, and 17 tasks without errors or warnings. Other findings, live Telegram Settings, and remote state remain unchanged. |
| 2026-09-08 | Add opt-in **Require a bot mention in groups** to Intercom. Exact Telegram mention entities gate group prompts, commands, typed answers, edits, and Attachment intake before effects; private Messages and Keyboard taps remain unchanged. Red/green regressions, 195 Intercom cases, and 13 native UI cases pass. The full Sampler gate passed 2,537 tests with 18 child/browser skips, zero failures, and 17 tasks without errors or warnings. Built-preview persistence and desktop/mobile checks passed. Normal Telegram Settings are untouched; no live Telegram test, child-profile proof, push, or publication. |
| 2026-09-07 | Merge the Turn-grant and single-child V3 chain into local `main` as `e109c55` after an independent security review, then close its one High finding test-first. An approval card no longer shortens a command, URL or form value while dispatching the whole string, and no longer fingerprints the shortened copy — two values sharing a 500-character prefix previously produced the same card and the same answer. Content above the card's ceiling is refused instead of shown in part, and Local Terminal gained the 2,000-character guard Isolated and child Terminal already had. Nine tests written first failed for the right reasons, then passed; the merged and fixed tree passed 2,514 tests with zero failures, five existing skips, and 16 tasks without errors or warnings. Two Minor findings stay open: unobserved child stderr drains and a missing `stopTurn` route test. No push, no publication, and child execution remains disabled pending a fresh built-runtime proof. |
| 2026-09-07 | Store a standalone Desktop roadmap and user-testing guide covering verified repository state, safe temporary-data launch, Turn-wide/once/Stop/Isolated acceptance checks, pass/fail recording, post-acceptance Merge gates, and remaining File/MCP, Parallel Agents, and Microsoft Graph work. Render and secret-pattern checks passed; repository records remain authoritative. |
| 2026-09-07 | Independent security/quality review approved Turn-wide Terminal grants with zero Blockers/Majors and one Minor test gap. Added the complete Terminal execution-policy revocation matrix; 117 approval contracts passed against merged ShellPilot. ShellPilot child-provider support merged into `main` as `4ab9eed`, passed 1,937 tests with three existing Unix-only skips and 89.04% coverage, then was pushed to `origin/main`. No package publication. |
| 2026-09-07 | Add operator-requested ordinary Terminal **Allow for this Turn**, bound to Tool/class, Conversation/Turn, Project/directory, and execution policy. Stop, end/failure, and window/Intercom scope changes revoke it; browser/child approvals remain once-only. Focused 105 cases plus three Intercom regressions passed; final full gate 2,497 passed, five existing skips, no failures/unrun, 16 tasks without errors/warnings. Real-HTTP proof verified two commands with one Turn grant and fresh approvals next Turn; desktop/mobile passed. Updated prompt roadmap and ShellPilot merge guidance; Engine itself was not changed or merged. |
| 2026-09-07 | Complete accepted single-child V3 with explicit estimated provider budgets, separate credentialless Engine/Tool containers, exact approvals, hard local limits, Stop/recovery, and private proposals. Final Engine: 1,915 passed, 89.2% coverage; DeskPilot: 2,454 passed, five existing skips, no failures or unrun cases. Both full gates: 16 tasks, zero errors/warnings. Independent Major/Minor fixed red/green and rechecked; approval conditions satisfied. Built-controller authenticated proof: 1,601 input/87 output tokens, USD 0.002036, unchanged Project and verified cleanup. Real built SPA passed desktop/mobile; local proof is ready but child execution stays disabled. No push/publication; clean-install Engine distribution remains separate. |
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
- Single-child V3's authenticated complete built-runtime proof and independent
  review are now complete; do not repeat the earlier counter investigation as
  a V3 blocker. Terminal-only live acceptance remains a separate profile.
- Make a dispatch-enforcing Engine obtainable for clean installations. Staged
  ShellPilot 0.4.1 passes; installed 0.4.0 fails closed. The DeskPilot Preview
  publication does not by itself prove clean-install Engine availability.
- The CI repair is merged and pushed to `main`; hosted tests and Preview
  publication are verified. Further runtime acceptance remains separate work.

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
