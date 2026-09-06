---
schema-version: 1
status: accepted
owner: shared
last-verified: 2026-09-06
source: repository evidence and prerequisite reassessment
---

# Active context

## Current focus

Bounded parallel Agents were assessed on 2026-09-06 and stopped at the user's
prerequisite gate. The deliverable is the revised
[decision 0005](decisions/0005-parallel-agents.md) and its dependency plan,
not a concurrent runtime. The topology and limits are proposed and still require
operator approval. No runtime, Settings, API, UI, or test implementation changed.

Work is on `ai/parallel-agents-prerequisite-plan`, based on `9d8211b` from the
completed isolated Terminal documentation cycle. Source, tests, and build
settings remain at implementation `f6af6fd`. No push or publication is requested.

## Verified prerequisite state

- Terminal approval is locally implemented and tested. The focused suite passed
  **65 tests, zero failures, zero skips**, using Pester 5.7.1 and staged
  ShellPilot 0.4.1 with real dispatch, scripted provider responses, and inert
  executors. The corrected detached wrapper exited 0 at 07:15 UTC.
- Terminal isolation now exists, but does not isolate native File Tools, MCP,
  other child state, or child credentials. A read-write Project bind has no
  total disk quota and is not a private child working tree.
- `Invoke-ShpBatch` is bounded concurrency, not the required delegation
  contract. It forces streaming/progress off, uses empty history, cannot replay
  DeskPilot's injected Tool implementations, and checks completed spend rather
  than reserving aggregate in-flight cost.
- Additional Runspaces isolate Tool tables and Runspace globals, not the
  process environment or filesystem. The historical import measurements are
  not a child containment or performance proof.

## Proposed next work

Resolve the enforcing Engine's obtainable contract and a complete single-child
execution/storage profile before approving the new topology. Proposed children
have separate supervised processes, quota-enforced work areas, per-child
approvals, bounded context and Usage, and independent cleanup. Parent planning
and synthesis are tool-free; all real Project changes require one reviewed,
conflict-aware apply operation with a recoverable journal.

Decision 0005 records the dependency order, numeric caps, threat model,
cancellation/restart behavior, and required test-first proofs. No delegation
runtime work starts until those prerequisites and operator approval are met.
The six runtime specifications remain unchanged pending an approved design.

## Verification and review

An independent security review completed 2026-09-06 and returned request
changes: zero Blockers, one Major review-state inconsistency, and one Minor
missing retained Markdown artifact. The decision renders; six local documents
were rendered and 27 local links resolved. Author-verified documentation
corrections were applied for these findings; there has been no independent
re-review and no operator topology approval. See decision 0005 for the retained
evidence artifact basenames under `$env:TEMP` and the retained validation
record. The prerequisite-test versus runtime-proof distinction remains: full
delegation, stress, and clean live proofs cannot establish a feature whose
isolation mechanism is not implemented and whose topology is unapproved.

## Retained release follow-ups

Optional isolated Terminal implementation, prior full Sampler/Docker/UI evidence,
and its documentation closeout remain in
[decision 0001](decisions/0001-isolated-tool-execution.md) and the
[operator guide](../docs/isolated-terminal.md). The previous live attempt returned
`auth_required`; live operator acceptance and an obtainable enforcing Engine
remain separate release gates. No authentication or production Settings were
changed for this assessment.

Earlier browser and Intercom detail remains in the
[archived active context](archive/active-context-2026-09-05.md).
