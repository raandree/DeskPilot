---
schema-version: 1
status: accepted
owner: software-engineer
last-verified: 2026-10-02
source: red/green Pester and Node regressions, real-Engine scripted-provider journey, headless Edge renders
---

# Active context

## Current focus

**Subagents**, as in the VS Code chat screenshot the user shared, on
`ai/subagents` from `main` `9d3890c`. No push or Merge was requested.
Decision: [0012](decisions/0012-bounded-subagents.md); guide:
[docs/subagents.md](../docs/subagents.md).

- `run_subagent` is a DeskPilot User Tool. The Engine's `Invoke-ShpSubagent`
  (spec 045) runs the Subagent synchronously as a strict subset of the Turn.
  The Turn waits, so there is no concurrency and decision 0005 is untouched.
- `permissions.subagents` defaults **off** and needs User Tools plus an Engine
  that passes `Test-DpSubagentSupport` (`subagentsSupported` on `/api/health`).
- Host-owned context travels as `$global:DeskPilotSubagentContext`: catalog,
  parent capability (Disable* switches plus the Turn's own `ToolCallControl`),
  Turn identity, limits and ledger. A legacy `ToolCallApprover` turns Subagents
  off.
- DeskPilot's Invoker (`ConvertTo-DpSubagentTurnParameter`) mirrors the
  Engine's dispatcher and adds Model, ReasoningEffort, DisableTodoList and
  ExcludeTool (`run_subagent`, `ask_questions`). A parity test against the
  installed Engine guards it.
- Subagent Terminal commands are approved once only and neither use nor create
  a Turn-wide grant.
- `DeskPilotSubagent` records become `activity` frames of kind `agent`
  (started/finished). Child Tool calls nest via `parentId`, and the child's Task
  List is ignored. Turn Usage merges the Engine delta with the runs' real
  round-trips, and child writes join pending changes. The UI shows one card per
  run with Input, Tool calls and Output.

## Validation

- Full Sampler gate: 3,068 passed, 0 failed, 15 skips; 16 tasks, 0 errors,
  7 known Memory preservation warnings. Node UI tests: 101/101.
- `tests/Unit/Subagents.Tests.ps1` (87) and `StopTurnRoute.Tests.ps1` (4) also
  pass under `Set-StrictMode -Version Latest`. They include an end-to-end run
  through the installed Engine (0.4.0-preview0016) with a scripted provider,
  where the dispatch and the Subagent's write both met the Turn's approval
  control. A parity guard against the Engine's dispatcher was mutation-checked.
- Headless Edge renders of the real functions and stylesheet look right in dark,
  light and a 390 px column. Not a live Model run.

## Retained boundaries

Parallel/background agents stay blocked by decision 0005. The isolated child
run (0009/0010) is a different feature and is unchanged. Terminal-only approval
remains the default; Permissions other than the new one are unchanged. Never
price Models in DeskPilot.

## Open follow-ups

- A live, authenticated Model run of a Subagent has not been done. It belongs to
  the operator acceptance profile.
- An independent security review of the Subagent approval inheritance is
  recommended (`review: on`); none was dispatched.
- The other 2026-09-07 Minor finding, unobserved child stderr drains in the
  isolated child runtime, stays open. It touches source-bound child proof.
