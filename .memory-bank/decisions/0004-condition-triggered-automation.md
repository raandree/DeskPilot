---
schema-version: 1
status: accepted
owner: software-engineer
last-verified: 2026-09-02
source: repository evidence
---

# 0004 — Condition-triggered automation: shipped in safe mode

## Status

**Implemented 2026-09-03**, restricted to the `safe` permission mode. The record
below keeps the original gate analysis because the reasoning still governs what
the feature may and may not do.

## The gate, and why shipping does not bypass it

`.github/prompts/implement-event-triggered-automation.prompt.md`:

> Stop after design if per-call approval and safe scheduled-work dispatch are not
> implemented. Do not create a second scheduler or Engine Runspace to bypass
> those prerequisites.

- **Safe scheduled-work dispatch: implemented** — the bounded FIFO queue,
  claim-based restart recovery and single-active-Turn dispatcher in
  `Update-DpScheduleState`.
- **Per-call approval: still absent** (`specs/120`, decision 0001).

The gate exists to stop an externally timed run holding authority nobody is
present to approve. That is exactly what the `safe` permission mode already
enforces for scheduled work: live Permissions ANDed down, **Terminal removed**,
Project confinement, and a stored prompt independent of the event. A trigger
locked to that mode therefore satisfies the gate's purpose rather than working
around it — and `live` mode is refused outright, in the UI *and* in the API,
until the approval contract exists.

No second scheduler was created: a trigger **is** a schedule whose clock is a
file instead of a time (`recurrence: onFileChange`), so it reuses the store, the
queue, coalescing, the claim, the run history, the routes and the run path.

## Why the approval half genuinely matters here

Scheduled work is started by a clock the user set. A file trigger is started by
*a file appearing*, and a file can be put there by something other than the user
— a sync client, a colleague's share, a download. The gap between "the user
chose this moment" and "something outside chose this moment" is precisely the gap
per-call approval closes. That is why the feature ships without Terminal rather
than with it.

## What was built

**Event source.** One: a local file event inside the selected Project, at a fixed
Project-relative path or glob (`incoming/*.csv`). Nothing else — no webhook, no
inbound listener, no mailbox poll, no cloud bus.

**Stability.** A file is not input until it stops changing: size and last-write
time unchanged across two consecutive scans at least `stabilitySeconds` apart
(default 3, configurable 1-3600). A partial write is never processed as completed
input. The share-deny-write probe in the original design was dropped: the
signature comparison already establishes the same fact without opening a handle
that could itself block a writer.

**Identity and deduplication.** Event identity is `(normalized relative path,
size, last-write UTC)`. That triple is the deduplication key across rename
storms, delete/recreate cycles and Host Server restarts; it is persisted on the
schedule record as `seen`, pruned when a file disappears so it stays bounded.

**Confinement.** Checked twice, at different times. The `watchGlob` is refused at
save time when it is rooted or contains a `..` segment; the scan then prunes any
directory or file that is a reparse point instead of following it, so a junction
planted inside the Project cannot walk the scan out of it.

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
history and `Invoke-DpScheduledTurn` all carried over unchanged; the genuinely
new parts are `Get-DpAutomationEvent` (the scan, the stability window and the
dedup key) and one extra step in the dispatcher.

## Deliberately still not done

- **`live` permission mode for a trigger.** Blocked on `specs/120`.
- **Any event source other than a local Project file.** No webhook, no inbound
  listener, no mailbox poll, no cloud bus — all remain explicit non-goals.
- **A `FileSystemWatcher`.** The scan runs on the accept loop's idle tick and is
  bounded by a file cap; a watcher would add an event-ordering and reconnect
  problem the polling scan does not have, and the dedup key already survives a
  restart.
