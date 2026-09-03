---
schema-version: 1
status: accepted
owner: software-engineer
last-verified: 2026-09-03
source: repository evidence
---

# 0005 — Parallel Agents: architecture decision and dependency plan

## Status

**Blocked at the prerequisite gate.** Decision and dependency plan recorded; no
concurrency was added.

> **Partly superseded 2026-09-03.** Per-call approval shipped for Terminal
> (decision 0008), so half the gate below is now met. Isolation is not shipped
> and the single-Runspace finding stands, so the verdict is unchanged.
>
> **Re-verified 2026-09-03, later the same day.** The approval half is now met
> *conditionally* — enforcement needs an Engine build that does not exist on the
> Gallery. Isolation is still absent from `source/`. And the Engine's only
> concurrency contract was measured for the first time: `Invoke-ShpBatch` is
> real, bounded and accounted, and it is structurally unusable for delegation
> here. The verdict is unchanged.

## The gate

`.github/prompts/implement-parallel-agents.prompt.md`:

> Confirm per-call approval and an appropriate isolation mechanism are shipped
> and tested. If either is absent, stop after writing an architecture decision
> and dependency plan. Do not add concurrency to the current shared Engine
> Runspace or shared writable Project state.

**Approval — met, but only against an unreleased Engine.** `Test-DpApprovalActive`,
`Invoke-DpTerminalApprovalTool` and the `run_terminal_command` registration ship,
and `Initialize-DpTerminalTool` probes `Invoke-Shp` for the `offeredBuiltInTool`
refusal and throws without it. That refusal exists in the locally built
`output/RequiredModules/ShellPilot/0.4.1` and **not** in the installed `0.4.0`,
which is the newest published build. So the gate is honoured on this machine and
would fail closed on any other. `perCallApproval` also still defaults to `$false`.

**Isolation — absent.** `source/` contains no container, sandbox, scratch-worktree
or confinement code of any kind; the only matches for those words are an MCP
`sandboxRequested` badge and the browser's `<iframe sandbox>`. Decision 0001's
blockers stand: the Docker/WSL2 dependency is unapproved and this machine has no
container runtime, no WSL and Windows Sandbox disabled, so no isolation claim
could be proven against a backend even if one were written.

One half open is not the gate open. Stop stands.

## A third blocker, from the Engine — corrected 2026-09-03

The prompt requires verifying the Engine's delegation and concurrency contract
from source. DeskPilot holds **one** `[runspacefactory]::CreateRunspace()`
(`Initialize-DpEngine`), and every Turn runs `Invoke-Shp` on it. ShellPilot
exposes no child-agent, sub-agent or delegation contract at all — `subagent`,
`sub-agent`, `child agent` and `delegat` each occur **zero** times in both 0.4.0
and 0.4.1. It does expose one bounded concurrency contract, measured below.

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

## The Engine's one concurrency contract, and why it cannot carry a child

Measured 2026-09-03 against `ShellPilot.psm1` 0.4.1, identical in 0.4.0. The
earlier claim that the Engine offers nothing was too broad: **`Invoke-ShpBatch`
is exported**, and it is a genuine bounded fan-out. `-ThrottleLimit` is
`ValidateRange(1, 64)` with a default of 4; `Invoke-ShpParallel` (private) wraps
`ForEach-Object -Parallel`; `-MaxBatchBudgetUSD` gates dispatch against a
`ConcurrentBag` of spend; each item returns a `ShellPilot.BatchResult` carrying
`Index`, `Id`, `Success`, `Skipped`, `BudgetExceeded`, `Usage`, `CostUSD`,
`Credits`, `Iterations`, `ToolCallCount`, `DurationMs` and `Error`; and the
per-item usage records are merged back into the caller's `$script:ShpUsageLog`.
Bounded fan-out, honest accounting and a per-child result envelope are exactly
what this prompt asks for, and they already exist.

It still cannot be the mechanism, and the reasons are structural rather than
missing features. `Invoke-ShpBatch` forces four values onto every item:

| Forced | Line | What it costs a DeskPilot child |
| --- | --- | --- |
| `DisableUserPrompts = $true` | 12638 | No Ask-User. **The approval bridge is Ask-User's rendezvous**, so a batch child can never park for an approval — the per-call gate is not merely absent, it is unreachable |
| `DisableProgressEvents = $true` | 12639 | No `ToolCall` progress records, which is the only source `Get-DpStreamFrame` has. No live Activity, no Thinking, no per-child evidence |
| `DisableStreaming = $true` | 12637 | No token deltas, so no child progress to expand under the parent Turn |
| `History = @()` | `Invoke-ShpBatchItem` | Stateless by construction — the minimum parent context the prompt requires cannot be passed as history |

And the tool table does not survive. A worker runspace "has inherited nothing";
`Invoke-ShpBatchItem` replays the session context, the model-limit cache, the
tool policy, the redaction policy and then the registered tools **by command
name**, catching the failure:

> A tool backed by a function that exists only in the caller's session cannot be
> re-registered, because a worker runspace cannot see it. Report it rather than
> failing the batch.

Every DeskPilot Tool is exactly that. `Initialize-DpQuestionnaireTool`,
`Initialize-DpWorkspaceTool` and `Initialize-DpTerminalTool` all inject their
backing functions into the Engine Runspace with `AddScript` before calling
`Register-ShpTool`; none is a module-exported command. So `ask_questions`,
`search_files`, `search_text`, `replace_in_file` and `run_terminal_command`
would each be skipped with a warning, and MCP is refused outright with a warning
of its own.

**The composite failure is the important one.** A batch child would keep the
Engine's *built-in* tools — including `run_command` — while silently losing
DeskPilot's `run_terminal_command` and the bridge that gates it. Unless the
caller also passed `-DisableTerminal`, that child would run commands on the host
with no card and no denial: the same bypass fixed upstream this morning, reached
by a different route and this time with no Engine defect to blame. Passing
`-DisableTerminal` is the correct call and leaves the child with no terminal at
all, because the gated replacement cannot register either. There is no
configuration of `Invoke-ShpBatch` in which a child has *approved* Terminal
access.

`Invoke-ShpBatch` is therefore right for stateless graded sweeps and wrong for
delegation. The topology below — DeskPilot creating and owning each child
Runspace, injecting its own Tools exactly as it does for the parent — is not a
workaround for an Engine that lacks concurrency. It is the only shape in which a
child can hold DeskPilot's boundaries at all.

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

1. **A published Engine that carries the dispatch refusal.** The approval half of
   the gate is honoured today only against a locally built 0.4.1. Until that
   ships, every other machine fails the capability probe and runs with no gate,
   so no delegation may be enabled on the strength of it. `specs/120` is still
   required separately, for MCP and for gating the built-in File Tools in place.
2. Isolation backend (decision 0001) — a writable child is exactly the case that
   needs it.
3. **A child Runspace factory that carries DeskPilot's own Tools and its own
   approval bridge.** New, from the batch measurement above: a child that cannot
   register `run_terminal_command` and cannot park on a bridge must hold neither
   Terminal nor File write, and that has to be structural rather than a default.
   The reconcilers already take `-Runspace`, so the work is a factory, orphan
   reaping, a per-child bridge instance and a Diagnostics probe for child
   lifecycle.
4. Per-variable environment allow-list — the last genuinely process-wide state.
   Decision 0001 needs it anyway, so it is shared work rather than extra work;
   process-global CWD is closed.
5. Scratch-worktree creation, merge review and rollback, built on the existing
   snapshot and change-set machinery.
6. Only then: fan-out limits, aggregation UI, and the stress tests for ordering
   and races the prompt requires.

Steps 1 and 2 remain the gate. Steps 3 and 4 can be investigated independently
and are both known to be small.
