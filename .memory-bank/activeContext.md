---
schema-version: 1
status: accepted
owner: shared
last-verified: 2026-09-03
source: repository evidence
---

# Active Context

## Current focus

**Per-call approval for Terminal commands is implemented and committed**
(`223ecfe`, branch `ai/competitive-landscape-2026`, unpushed). The design was
interrogated with `grill-me`, signed off by the operator, and built the same
day. The Design Concept is at `.memory-bank/topics/design-per-call-approval.md`;
the durable choices are in `.memory-bank/decisions/0008-per-call-approval.md`.

Gate at the last run: **1656 tests passing, 16 tasks, 0 errors, 0 warnings.**

## What shipped

DeskPilot registers its own `run_command` into the Engine Runspace and passes
`-DisableTerminal`, so the Engine built-in is neither offered to the Model nor
reachable through its dispatch switch. The owned Tool blocks on a dedicated
approval bridge before it calls anything, then delegates execution to the
Engine own `Invoke-RunCommandTool`.

The gate is tiered: a shipped allow-list of read-only commands runs without
asking, everything else prompts, and a shell operator disqualifies a command
before any matching. There is no Turn-wide grant - the grant subsystem written
earlier the same day was deleted.

New files: `Get-DpSafeCommandList`, `Test-DpCommandSafe`, `Test-DpApprovalActive`,
`Initialize-DpTerminalTool`, `Set-DpTerminalTool`, `Send-DpIntercomApproval`.
Deleted: `New-DpApprovalState`, `Add-DpApprovalGrant`, `Resolve-DpApprovalGrant`.

## Deliberate gaps, not oversights

- **`perCallApproval` ships off.** Default-on without operating experience of the
  card would park a Turn for the full 15-minute timeout on the first
  unrecognised command. It flips on in a later slice.
- **There is no Settings UI for `safeCommands` or `approvalTimeoutMinutes`.**
  Both are accepted and validated by the API; neither has a control yet.
- **A pending approval is not yet re-rendered by the SPA on reload.**
  `GET /api/conversations/{id}/approval` serves it, but nothing calls that route
  on load.
- **Intercom denial notes are not collected.** The phone can approve or decline;
  the note field exists only in the window.

## Still genuinely blocked

MCP calls and the Engine built-in File Tools cannot be gated without the
upstream contract in `specs/120`. That record was rescoped, not retired: it is
still true for those two surfaces, and no longer true for Terminal.

## The lesson this session keeps re-teaching

Three inherited claims in this repository were measured and found wrong within
two days. A blocker shapes the roadmap, so it earns the same evidence bar as a
bug fix. Recorded in `systemPatterns.md` under anti-patterns.
