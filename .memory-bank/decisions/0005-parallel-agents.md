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

## A third blocker, from the Engine

The prompt requires verifying the Engine's delegation and concurrency contract
from source. DeskPilot holds **one** `[runspacefactory]::CreateRunspace()`
(`Initialize-DpEngine`), and every Turn runs `Invoke-Shp` on it. ShellPilot
exposes no child-agent or sub-agent contract, and its Tool registrations
(`Register-ShpTool`) are **runspace-scoped global state**: `Initialize-DpSearchTool`
and `Set-DpQuestionnaireTool` re-register per Turn precisely because that state is
shared. Two children on one Runspace would therefore share Tool registrations,
`$global:DeskPilotSearchRoot`, and the working directory — which is the opposite
of what delegation requires.

So parallelism means N Engine Runspaces (or N processes), each with its own
imported ShellPilot, its own Tool registrations, and its own working tree. That
is a genuinely large change, and it is the reason this feature sits last behind
approval and isolation rather than being an incremental option.

## Topology decision

**One process, N+1 Runspaces, N ≤ 2.** A child gets its own Runspace with its own
ShellPilot import and its own registered Tools; the parent Runspace is untouched.
Separate *processes* were considered and rejected for the first slice: they would
need an IPC protocol for progress, Usage and cancellation that the in-process
`Streams.Information` drain already provides.

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
3. Multi-Runspace Engine lifecycle: import cost, memory ceiling, orphan reaping,
   and a Diagnostics probe for child lifecycle and orphans.
4. Scratch-worktree creation, merge review and rollback, built on the existing
   snapshot and change-set machinery.
5. Only then: fan-out limits, aggregation UI, and the stress tests for ordering
   and races the prompt requires.
