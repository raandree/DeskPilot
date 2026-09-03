---
description: "Implement bounded condition-triggered automation for DeskPilot"
agent: "software-engineer"
---

# Implement condition-triggered automation

## Why this feature is useful

Some recurring work starts when something changes, not when a clock reaches a
fixed time. A bounded event trigger can start review promptly while avoiding
constant polling and repeated manual prompts.

## Use case

An operations lead drops a new report into a Project's `incoming` directory.
DeskPilot detects the completed file, waits for the Engine to become idle, and
creates a Turn that validates the report and drafts a summary. The run never
executes outside that Project and cannot perform an action needing fresh approval.

## Objective

Implement one local, condition-triggered automation after scheduled work and
per-call approval exist. Preserve one active Turn and make event provenance,
deduplication, collision, Permission, approval, and recovery policies explicit.

## Required context

Read `specs/010-requirements.md`, `specs/020-architecture.md`,
`specs/030-api-contract.md`, `specs/040-ui-design.md`,
`specs/050-security-model.md`, `specs/060-roadmap.md`, the scheduled-work
contract, and the Turn, Permission, Activity, Usage, Intercom, Project
confinement, and persistence patterns in `.memory-bank/systemPatterns.md`.
Trace startup, shutdown, Project switching, scheduling, pending requests, and
the single-active-Turn dispatcher.

## Prerequisite gate

Stop after design if per-call approval and safe scheduled-work dispatch are not
implemented. Do not create a second scheduler or Engine Runspace to bypass those
prerequisites.

## Specify before implementation

Record and present a concrete contract for:

- The first event source and exact condition grammar.
- Event identity, provenance, debounce, stability, deduplication, and replay.
- Collision with interactive and scheduled Turns.
- Backlog bounds, coalescing, expiry, retry, cancellation, and restart recovery.
- Captured versus live Project, Agent, Model, Prompt File, and Permission state.
- Actions that require fresh approval and therefore cannot run unattended.
- Result placement, Unread state, Activity, Usage, changed files, and Intercom.

Prefer a local Project file event with a fixed relative path or glob. Treat the
event payload as data and keep the stored prompt independent from file contents.

## Required behavior

- Support create, edit, enable/disable, run now, and delete for one local trigger.
- Persist a stable automation id, event source, bounded condition, prompt,
  Project, enabled state, collision policy, next eligibility, and last outcome.
- Wait for a file to become stable before opening it; do not process partial
  writes as completed input.
- Normalize and confine every event path to the selected Project.
- Deduplicate events across watcher reconnects and Host Server restart.
- Queue through the same single-active-Turn policy as scheduled work.
- Revalidate Project, Agent, Model, Prompt File, and Permissions at execution.
- Refuse or pause any action that requires unanswered per-call approval.
- Preserve Activity, Usage, pending changes, Checkpoints, Stop, and Intercom.
- Show trigger provenance and the reason each event ran, coalesced, expired, or
  was refused.

## Security and reliability boundaries

- Treat file names, paths, metadata, and contents as untrusted input.
- Do not interpolate event content into commands, URLs, or Tool arguments.
- Do not follow links or reparse points outside the Project.
- Bound watcher count, event rate, queue size, retained history, and file size.
- Handle rename storms, temporary files, delete/recreate cycles, sleep, and
  network-drive disconnects without duplicate execution.
- Do not add webhooks, inbound listeners, mailbox polling, or cloud event buses.
- Do not run while DeskPilot is stopped.

## Test-first proof

Write failing Pester tests with injectable event and clock sources. Cover at
least:

- Stable file creation, partial writes, rename, duplicate, delete, and recreate.
- Path traversal, links, reparse points, and events outside the Project.
- Debounce, coalescing, queue limits, expiry, collision, and manual run behavior.
- Restart before, during, and after an event claim without duplicate execution.
- Missing Project, Agent, Model, and Prompt File behavior.
- Permission reduction, approval-required actions, Stop, and late callbacks.
- Activity, Usage, Unread, changed-file, and Intercom result recording.
- Prompt-injection content in the triggering file remaining data only.

## Definition of done

- Update requirements, architecture, API contract, UI design, security model,
  and roadmap with the approved event and recovery contract.
- Add an accessible automation surface with trigger, status, backlog, last-run,
  and failure states.
- Run focused tests, parsing, PSScriptAnalyzer, JavaScript syntax checking when
  applicable, and the full Sampler build and test gate.
- Update `CHANGELOG.md` and routed Memory Bank records.
- Commit on a focused topic branch. Do not push.

## Non-goals

- Webhooks, inbound network listeners, email triggers, or cloud event ingestion.
- Natural-language conditions evaluated continuously by a Model.
- Parallel Turns or a second Engine Runspace.
- Hidden escalation of Permissions.
- Operating-system service installation or operation while DeskPilot is closed.