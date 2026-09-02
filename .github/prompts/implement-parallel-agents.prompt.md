---
description: "Design and implement bounded parallel Agent delegation in DeskPilot"
agent: "software-engineer"
---

# Implement parallel Agents

## Why this feature is useful

Independent subtasks can finish faster and benefit from specialist Agents, but
unbounded concurrency would multiply cost, authority, and merge ambiguity.
DeskPilot needs delegation that stays visible and reviewable rather than a hidden
swarm sharing one Workspace Folder.

## Use case

A researcher asks for a market brief. One child Agent reviews internal source
files while another gathers public evidence. Each has a bounded Tool set,
separate Activity and Usage, and an isolated work area. The parent presents both
results and one reviewable proposal instead of letting children overwrite the
same files.

## Objective

Implement a bounded parent-and-child delegation model with separate context,
Permissions, Usage, Activity, cancellation, and change review. Preserve the
meaning of Conversation and Turn for the user.

## Prerequisite gate

Confirm per-call approval and an appropriate isolation mechanism are shipped and
tested. If either is absent, stop after writing an architecture decision and
dependency plan. Do not add concurrency to the current shared Engine Runspace or
shared writable Project state.

## Required context

Read `specs/010-requirements.md`, `specs/020-architecture.md`,
`specs/030-api-contract.md`, `specs/040-ui-design.md`,
`specs/050-security-model.md`, and all Engine Runspace, Conversation isolation,
Usage, Activity, pending-change, Checkpoint, Stop, and Intercom patterns in
`.memory-bank/systemPatterns.md`. Verify the Engine's supported delegation and
concurrency contracts from source or current primary documentation.

Create and approve a decision record covering process/runspace topology, child
state, scheduling, context construction, Project isolation, result aggregation,
file merge, cancellation, quotas, failure recovery, and rollback before editing
runtime code.

## Required behavior

- Begin with one parent and at most two child Agents; make the cap configurable
  only within a hard server-side maximum.
- Give each child an explicit task, Agent, Model, Tool set, Permission subset,
  context budget, iteration budget, and Usage budget.
- A child may receive less authority than its parent, never more.
- Keep child histories and system prompts separate. Pass only the minimum parent
  context required for the task and label retrieved content as untrusted data.
- Use read-only Project access unless a child receives an isolated writable work
  area. Never let children concurrently write the same working tree.
- Return structured results with provenance, status, Activity, Usage, and proposed
  changes. The parent must not treat child prose as trusted instructions.
- Present one parent Turn with expandable child progress and aggregate Usage,
  while retaining per-child evidence.
- Stop cancels the parent and every descendant; child failure may be retried only
  while observably side-effect free.
- Intercom reports a concise parent status and links users back to DeskPilot for
  multi-child review or approval.
- Bound queue length, depth, fan-out, total duration, tokens, Tool iterations,
  and writable storage.

## Security and consistency boundaries

- Apply the lethal-trifecta test independently to every child.
- Do not share ambient credentials, mutable global Tool state, approval grants,
  or Runspace globals between children.
- Prevent recursive delegation in the first slice.
- Correlate every event with parent Turn and child id; reject stale or cross-child
  approvals and results.
- Merge child file changes only through a deterministic, reviewable flow with
  conflict handling and a rollback path. Never use last-writer-wins.
- Count all child Usage honestly, including failed work when the Engine reports
  it.

## Test-first proof

Write failing tests before production changes. Cover at least:

- Two children progress independently without history, Tool state, or file
  leakage.
- Permission, approval, context, Usage, duration, and iteration caps are enforced
  per child and in aggregate.
- Concurrent write attempts cannot touch the same working tree.
- Child output cannot invoke parent Tools as instructions.
- Stop cascades and no descendant continues running or reporting afterwards.
- Partial failure, timeout, retry, Host Server restart, and orphan cleanup.
- Deterministic merge review, conflict handling, rejection, and rollback.
- Activity and Usage remain attributable and totals are correct.

Include stress tests for ordering and race conditions. Run the full suite and a
clean live proof with bounded, non-sensitive Projects.

## Definition of done

- Update requirements, architecture, API contract, UI design, security model,
  and roadmap with the approved topology and limits.
- Preserve ordinary single-Agent Turns without extra complexity or cost.
- Add Diagnostics for child lifecycle, orphan detection, and aggregate limits.
- Complete an independent security review and resolve all Blocker and Major
  findings before release.
- Update `CHANGELOG.md` and routed Memory Bank records.
- Commit on a focused topic branch. Do not push.

## Non-goals

- Unlimited Agent teams or recursive delegation.
- Concurrent writes to one working tree.
- Sharing Turn-wide approvals between parent and children.
- Hidden child Usage or Activity.
- Multi-user orchestration or a hosted control plane.