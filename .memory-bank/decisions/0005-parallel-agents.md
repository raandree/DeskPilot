---
schema-version: 1
status: accepted
owner: software-engineer
last-verified: 2026-09-02
source: repository evidence
---

# 0005 — Parallel Agents: architecture decision and dependency plan

## Status

**Blocked at the prerequisite gate.** Decision and dependency plan recorded; no
concurrency was added.

## The gate

`.github/prompts/implement-parallel-agents.prompt.md`:

> Confirm per-call approval and an appropriate isolation mechanism are shipped
> and tested. If either is absent, stop after writing an architecture decision
> and dependency plan. Do not add concurrency to the current shared Engine
> Runspace or shared writable Project state.

Neither is shipped (`specs/120`, decision 0001). Both halves are closed.

## A third blocker, from the Engine — corrected 2026-09-03

The prompt requires verifying the Engine's delegation and concurrency contract
from source. DeskPilot holds **one** `[runspacefactory]::CreateRunspace()`
(`Initialize-DpEngine`), and every Turn runs `Invoke-Shp` on it. ShellPilot
exposes no child-agent or sub-agent contract.

**The original version of this record then claimed that two children on one
Runspace would share Tool registrations and `$global:` state, and that fixing it
was "a genuinely large change". Measured on 2026-09-03, that claim was wrong**,
and it was wrong in the direction that matters: it made the blocker look bigger
than it is.

Three runspaces were opened in one process, ShellPilot imported into each, and a
Tool plus a `$global:` variable registered in the first only:

| Observation | Result |
| --- | --- |
| `Get-ShpTool` in runspace 1 / 2 / 3 | `probe_thing` / empty / empty |
| `$global:DeskPilotProbeRoot` in runspace 1 / 2 / 3 | `ONLY-IN-RS1` / empty / empty |
| `$PWD` set per runspace | held independently |
| Import cost | **752 ms** first, then **21 ms** and **17 ms** |
| Managed heap, three imports | **15 MB** total |

So the Tool table, `$global:` variables and the PowerShell location are **already
per-runspace**. ShellPilot has no process-global Tool registry, and DeskPilot's
own per-Turn reconciliation (`Set-DpQuestionnaireTool`, `Set-DpWorkspaceTool` —
both of which already take a `-Runspace` parameter) would move to a second
Runspace unchanged. The first import pays JIT and assembly load once; an
additional Engine Runspace costs roughly 20 ms and 5 MB.

## What is actually shared, and therefore actually needs a design

A second probe set two runspaces to two different working directories:

| State | Scope | Consequence |
| --- | --- | --- |
| `$PWD` (PowerShell location) | per runspace | fine |
| `[System.Environment]::CurrentDirectory` | process-global, last writer wins | **resolved 2026-09-03**: `Set-DpEngineLocation` no longer writes it, because no Tool reads it |
| Environment variables | **process-wide** | already recorded (2026-08-11, Engine Runspace environment divergence); still open |
| A child process spawned from a runspace | inherits that runspace's `$PWD`, not `[Environment]::CurrentDirectory` | measured: a child from runspace 1 reported runspace 1's folder while the process-global value pointed at runspace 2 |
| Engine OAuth token file | shared on disk | desirable |
| MCP attachments | per runspace, started from that runspace's `$PWD` | a second Runspace would start its own third-party server processes |

The working-directory half was closed by measuring what actually reads the
process value. With `$PWD` pointed at folder A and
`[System.Environment]::CurrentDirectory` at folder B, `read_file`,
`list_directory`, `write_file` and `run_command` all resolved against **A** (the
written file physically landed in A), and ShellPilot starts an MCP server from
`(Get-Location).Path` as well. Only a raw `[System.IO.File]` call with a relative
path followed B, and neither DeskPilot nor the Engine makes one. The write was
therefore removed, with a paired regression test.

What remains genuinely process-wide is the **environment block**. That is a
smaller problem than a working directory: it is read at process start by child
processes, and the isolation work (decision 0001) has to solve it anyway through
a per-variable allow-list.

## Topology decision

**One process, N+1 Runspaces, N ≤ 2.** A child gets its own Runspace with its own
ShellPilot import and its own registered Tools; the parent Runspace is untouched.
The measurements above confirm this is cheap (~20 ms, ~5 MB per child) and that
the isolation it needs is already the platform's default. Separate *processes*
were considered and rejected for the first slice: they would need an IPC protocol
for progress, Usage and cancellation that the in-process `Streams.Information`
drain already provides.

**One working directory at a time — no longer a constraint.** The process-global
`[System.Environment]::CurrentDirectory` write was removed on 2026-09-03, so each
child's working directory is its own runspace `$PWD`. Nothing in the Engine's
Tool set reads a process-wide location.

**Project isolation.** A child never writes the user's working tree. Each writable
child gets a git worktree-style scratch copy under the data directory; results
come back as a **proposed change set** reviewed through the existing pending-change
and diff surfaces. Read-only children get the Project read-only. Last-writer-wins
is not on the table.

**Authority.** A child's Permission set is the ANDed subset of its parent's — the
same rule and the same helper (`Get-DpScopedSettings`) this session introduced for
scheduled work. Turn-scoped approvals are never shared between parent and child.
Recursive delegation is refused in the first slice.

**Accounting.** Child Usage is added to the parent Turn's totals and retained
per child, including failed work the Engine reports. Hidden child cost is the
failure mode that makes delegation untrustworthy.

**Cancellation.** Stop cancels the parent and every descendant; a child failure
may be retried only while it is observably side-effect free.

## Dependency plan

1. Engine contract from `specs/120` → per-call approval.
2. Isolation backend (decision 0001) — a writable child is exactly the case that
   needs it.
3. Per-variable environment allow-list — the last genuinely process-wide state.
   Decision 0001 needs it anyway, so it is shared work rather than extra work.
   The runspace side needs only a factory plus orphan reaping and a Diagnostics
   probe for child lifecycle; process-global CWD is closed.
4. Scratch-worktree creation, merge review and rollback, built on the existing
   snapshot and change-set machinery.
5. Only then: fan-out limits, aggregation UI, and the stress tests for ordering
   and races the prompt requires.

Steps 1 and 2 remain the gate. Step 3 can be investigated independently and is
now known to be small.
