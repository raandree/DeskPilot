---
schema-version: 1
status: accepted
owner: software-engineer
last-verified: 2026-09-02
source: repository evidence
---

# 0004 — Condition-triggered automation: design recorded, gate half open

## Status

**Blocked at the prerequisite gate**, on one of its two conditions.

## The gate

`.github/prompts/implement-event-triggered-automation.prompt.md`:

> Stop after design if per-call approval and safe scheduled-work dispatch are not
> implemented. Do not create a second scheduler or Engine Runspace to bypass
> those prerequisites.

- **Safe scheduled-work dispatch: now implemented** (this session — the bounded
  FIFO queue, claim-based restart recovery and single-active-Turn dispatcher in
  `Update-DpScheduleState`). That half of the gate is open.
- **Per-call approval: not implemented** (`specs/120`, decision 0001). That half
  is closed, so the work stops after design.

## Why the approval half genuinely matters here

Scheduled work is started by a clock the user set. A file trigger is started by
*a file appearing*, and a file can be put there by something other than the user
— a sync client, a colleague's share, a download. The gap between "the user
chose this moment" and "something outside chose this moment" is precisely the gap
per-call approval closes. Shipping the trigger first would make an externally
timed, unattended Turn the cheapest thing in the product to arrange.

## The design, for when the gate opens

**Event source.** One: a local file event inside the selected Project, at a fixed
Project-relative path or glob (`incoming/*.csv`). Nothing else — no webhook, no
inbound listener, no mailbox poll, no cloud bus.

**Stability.** A file is not input until it stops changing: size and last-write
time unchanged across two consecutive polls at least 2 seconds apart, and it can
be opened for read with a share-deny-write handle. A partial write must never be
processed as completed input.

**Identity and deduplication.** Event identity is `(normalized relative path,
size, last-write UTC)`. That triple is the deduplication key across watcher
reconnects, rename storms, delete/recreate cycles and Host Server restarts, and
it is persisted with the same claim mechanism scheduled work uses.

**Confinement.** Every event path is normalized and proved to be inside the
Project before anything else happens; junctions, symlinks and reparse points that
resolve outside are refused, not followed.

**Dispatch.** The **same** queue and the same `Update-DpScheduleState` policy —
one entry per automation, coalescing, expiry, the single-active-Turn rule. The
prompt forbids a second scheduler and there is no reason to want one.

**Payload is data.** The stored prompt is independent of the file's contents. The
file name and path are passed as typed fields, never interpolated into a command,
a URL, or a Tool argument. Content is read by the Agent through the ordinary File
Tool, inside the Project, as untrusted data.

**Bounds.** One watcher per automation, at most 5 automations, at most 60 events
per minute before the automation pauses itself and says so, a bounded backlog,
and a file-size ceiling above which the event is refused rather than truncated.

**Reuse.** `ConvertTo-DpSchedule`, the store, the claim, the queue, the run
history and `Invoke-DpScheduledTurn` all carry over unchanged; the only genuinely
new parts are the watcher, the stability check and the dedup key.
