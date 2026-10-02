---
schema-version: 1
status: accepted
owner: software-engineer
last-verified: 2026-10-02
source: red/green Pester and Node regressions, real-Engine scripted-provider journey, headless Edge renders, full Sampler gate
---

# Active context

## Current focus

`ai/subagents`, from `main` `9d3890c`, carries two pieces of unattended work.
No push or Merge was requested.

### Subagents (`3ee65d2`)

As in the VS Code chat screenshot the user shared. Decision:
[0012](decisions/0012-bounded-subagents.md); guide:
[docs/subagents.md](../docs/subagents.md).

- `run_subagent` is a DeskPilot User Tool. The Engine's `Invoke-ShpSubagent`
  (spec 045) runs the Subagent synchronously as a strict subset of the Turn.
  The Turn waits, so there is no concurrency and decision 0005 is untouched.
- `permissions.subagents` defaults **off** and needs User Tools plus an Engine
  that passes `Test-DpSubagentSupport` (`subagentsSupported` on `/api/health`).
- Host-owned context travels as `$global:DeskPilotSubagentContext`: catalog,
  parent capability (Disable* switches plus the Turn's own `ToolCallControl`),
  Turn identity, limits and ledger. A legacy `ToolCallApprover` turns Subagents
  off. Subagent Terminal commands are approved once only and neither use nor
  create a Turn-wide grant.
- DeskPilot's Invoker (`ConvertTo-DpSubagentTurnParameter`) mirrors the
  Engine's dispatcher and adds Model, ReasoningEffort, DisableTodoList and
  ExcludeTool. A parity test against the installed Engine guards it. CI's pinned
  compatibility Engine `08a4a22` has the same Subagent sources as ShellPilot
  `main`; only its price table differs, which no Subagent test asserts.
- `DeskPilotSubagent` records become `agent` Activity; the UI shows one card
  per run with Input, Tool calls and Output.

### Open assessment findings

Closed test-first and recorded in
[assessment-log.md](assessment-log.md) as author-verified:

- FIND-010 (`439d3cf`): behavioural `stopTurn` route tests.
- FIND-013: `tests/Unit/SpaNodeTests.Tests.ps1` runs every
  `tests/Unit/*.test.mjs` under `node --test` inside the Pester gate. A
  deliberately failing Node test turned it red.
- FIND-014: the support bundle's Intercom section carries `requireGroupMention`.
- FIND-015: a failed `getMe` names the consequence that applies now and is asked
  again after 30 seconds, then 2, 10 and 30 minutes
  (`Add-DpIntercomIdentityFailure`). Storing a new token forgets the old bot
  name.
- FIND-016: un-addressed group chatter folds into one `unaddressed` audit line
  per chat (`Add-DpIntercomLog -Coalesce`, `messageCount`, `sinceUtc`); the SPA
  shows `×N since <time>`.

## Validation

- Full Sampler gate: 3,082 passed, 0 failed, 15 skips; 16 tasks, 0 errors,
  the 7 known Memory preservation warnings. The SPA Node wrapper ran inside it.
- Intercom suites 355/355, Diagnostics 49/49, Node UI 103/103. Subagent and
  stopTurn suites pass under `Set-StrictMode -Version Latest`; the Intercom
  suites set it themselves.
- The Subagent proof includes an end-to-end run through the installed Engine
  (0.4.0-preview0016) with a scripted provider. Headless Edge renders checked
  the Subagent cards in dark, light and a 390 px column. Not a live Model run.

## Retained boundaries

Parallel/background agents stay blocked by decision 0005. The isolated child
run (0009/0010) is a different feature and is unchanged. Terminal-only approval
remains the default; Permissions other than the new one are unchanged. Never
price Models in DeskPilot.

## Open follow-ups

- FIND-009 stays open on purpose: the fix belongs in the disabled isolated
  child runtime, whose live Docker and Model proof is bound to its source
  hashes. The assessment log records the remediation plan.
- A live, authenticated Model run of a Subagent has not been done. It belongs to
  the operator acceptance profile.
- An independent review is recommended (`review: on`) for the Subagent approval
  inheritance and the Intercom intake and audit changes; none was dispatched.
