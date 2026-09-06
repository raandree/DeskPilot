---
schema-version: 1
status: accepted
owner: shared
last-verified: 2026-09-06
source: operator-approved single-child design V2 and test-first implementation
---

# Active context

## Current focus

Implement the [single-child isolation prerequisite](decisions/0009-single-child-isolation.md).
The operator explicitly approved revised design V2 and limited tracked Engine
contract work on 2026-09-06. V2 uses Host Server integration, a credentialless
child Engine container, a separate network-disabled Tool container, and trusted
Engine-owned provider transport. The first proposal was not approved.

Work is on `ai/child-agent-isolation`, based on `2d86925`. ShellPilot work uses
the linked worktree `D:/Git/ShellPilot-child-isolation`, branch
`ai/child-provider-boundary`, based on `3446e32`. Preserve the unrelated modified
public test in the original ShellPilot worktree on `ai/edit-file-tool`.

The implemented portion is private Tool storage, selected baseline capture,
authenticated control records, bounded export, lease, Stop, explicit recovery,
retention admission, and the Host Server readiness/refusal surface. No child
Engine has been launched. The final checked-in component proof passed 87 tests,
including 19 real-container tests, with no failures or skips. DeskPilot's final
full Sampler gate passed 2,373 tests, no failures, and five existing browser
skips at 11:36 UTC. ShellPilot's full gate passed 1,749 tests, no failures/skips,
88.79% coverage. Both full builds completed 16 tasks with zero errors/warnings.

Independent security review returned request changes: zero Blockers, three
Majors, one Minor. The implemented baseline credential-filter defect is fixed
with 15 red/green negative cases and a positive ordinary-JSON case; all 31
baseline tests pass. This correction is author-verified, not independently
re-reviewed. The two Major acceptance gates remain: complete-request admission
and the integrated child Engine/approval/accounting profile. Retention age and
Host Server restart integration remain the Minor open gate. No release is ready.

No push, publication, new shared dependency, or host privilege change is
authorized. Parallel scheduling and real Project application remain excluded.

## Retained prerequisite evidence

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

## Blocked next work

Obtain a verified Engine/provider contract for whole-request token bounds,
Engine-priced reservations, failed/unknown Usage, and cancellation. The current
heuristic counter and completed-spend guard cannot enforce the approved caps.
`NoAutomaticRetry` and `RequestTransport` are local tracked groundwork only.
Do not install an ignored patch or treat a fixture as released support.

Complete the approved credentialless Engine container, trusted Engine transport
process, child-specific approvals, full-run resource/accounting limits,
restart/retention integration, and authenticated live proof. Keep
`Get-DpChildReadiness.ready` false and `startChildRun` refusing until those
contracts and proofs exist. Parallel scheduling and real Project application
remain later work in decision 0005. Runtime specifications now explicitly
describe the partial implementation and closed readiness gate.

## Earlier prompt and decision evidence

Earlier prompt authoring checks cover YAML frontmatter, native Markdown rendering,
local links, diagnostics, and the
[real-conversation acceptance cases](../.github/prompts/evals/child-agent-isolation.md).
No runtime test was rerun for that authoring task. Native Customization analysis
and repeated fresh-chat behavioral evaluations have not been run; static checks
do not establish workflow reliability. The new prompt requests independent
security review of the eventual implementation, not a review already completed.

The following review belongs only to the earlier decision-only task:

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
