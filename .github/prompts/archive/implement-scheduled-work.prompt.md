---
description: "Implement safe local scheduled work for DeskPilot"
agent: "software-engineer"
---

# Implement scheduled work

## Why this feature is useful

Recurring preparation is common knowledge work. Local schedules let DeskPilot
produce routine reports and reviews without making users restate the same prompt,
while preserving the evidence and control of an interactive Turn.

## Use case

Every weekday at 08:00, an operations lead wants DeskPilot to review a Project's
overnight reports and draft a status summary. If DeskPilot is busy, the run waits
according to a visible policy; when complete, its Conversation, Activity, Usage,
and changed files are available for review and Intercom announces the result.

## Objective

Implement persistent, local, time-based schedules for prompts. Preserve one
active Turn and make collision, missed-run, Permission, approval, result, and
failure policies explicit before a scheduled Turn can run.

## Required context

Read `specs/010-requirements.md`, `specs/020-architecture.md`,
`specs/030-api-contract.md`, `specs/040-ui-design.md`,
`specs/050-security-model.md`, `specs/060-roadmap.md`, and the Turn, Settings,
Activity, Usage, Permission, Intercom, and persistence patterns in
`.memory-bank/systemPatterns.md`. Trace startup, shutdown, Conversation creation,
Turn dispatch, pending requests, and Intercom delivery.

## Specify before implementation

Record and present a concrete contract for:

- Collision with an interactive or scheduled Turn.
- Missed runs after sleep, shutdown, clock changes, or delayed startup.
- Queue bounds, coalescing, expiry, cancellation, and retry.
- Local time zone, daylight-saving transitions, and invalid local times.
- Captured versus live Project, Agent, Model, Prompt File, and Permission state.
- Actions that require fresh approval and therefore cannot run unattended.
- Conversation placement, Unread state, changed-file review, and Intercom notice.

Prefer a bounded FIFO queue and an explicit `skip`, `run once when idle`, or
`expire` policy over hidden concurrency. Ask the user only where repository
evidence cannot determine the product choice.

## Required behavior

- Support create, edit, enable/disable, run now, and delete for local schedules.
- Begin with daily and selected-weekday recurrence plus one-time schedules.
- Persist a stable schedule id, prompt, Project, recurrence, time zone, enabled
  state, collision/missed-run policy, next run, and last outcome.
- Compute the next run deterministically and show it before saving.
- Revalidate the referenced Project, Agent, Model, and Prompt File at execution.
  A missing dependency fails visibly; never substitute another silently.
- Create a distinct Conversation or clearly delimited scheduled Turn so results
  cannot appear inside an unrelated active Conversation.
- Apply the current category Permissions unless the approved specification
  defines a safer immutable snapshot. Never increase Permissions automatically.
- Do not run actions that require unanswered per-call approval. Mark the job as
  awaiting review or failed according to the approved contract.
- Preserve Activity, Usage, pending changes, Checkpoints, Stop, and Intercom.
- Bound retained run history and queue size.

## Security and reliability boundaries

- Treat stored prompts and referenced Project content as untrusted at execution.
- Do not add webhooks or network listeners in this feature.
- Use monotonic elapsed time for in-process waiting and wall-clock time only for
  schedule calculation. Do not busy-wait or block the accept loop.
- Prevent duplicate execution after restart with an atomic persisted claim or
  equivalent single-user recovery record.
- Make system sleep, backward clock jumps, and forward clock jumps testable.
- Refuse overlapping execution instead of creating a second Engine Runspace.

## Test-first proof

Write failing Pester tests with an injectable clock. Cover at least:

- Daily and weekday next-run calculation across daylight-saving transitions.
- Collision, coalescing, queue limit, expiry, and manual `run now` behavior.
- Restart before, during, and after a claimed run without duplicate execution.
- Missing Project, Agent, Model, and Prompt File behavior.
- Permission reduction, approval-required actions, Stop, and late callbacks.
- Activity, Usage, Unread, changed-file, and Intercom result recording.
- Corrupt schedule storage falls back visibly without losing unrelated Settings.

## Definition of done

- Update requirements, architecture, API contract, UI design, security model,
  and roadmap with the approved schedule contract.
- Add an accessible schedule management surface and visible next-run/outcome
  states without turning the main screen into an operations dashboard.
- Run focused tests, parsing, PSScriptAnalyzer, JavaScript syntax checking when
  applicable, and the full Sampler build and test gate.
- Update `CHANGELOG.md` and routed Memory Bank records.
- Commit on a focused topic branch. Do not push.

## Non-goals

- Webhooks, file watchers, email triggers, or external event ingestion.
- Parallel Turns or a second Engine Runspace.
- Hidden escalation of Permissions.
- Operating-system service installation.
- Cloud scheduling when DeskPilot is not running.