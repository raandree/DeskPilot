---
schema-version: 1
status: proposed
owner: software-engineer
last-verified: 2026-09-06
source: DeskPilot 275cd6b, tracked Engine d1e1e13, and prerequisite evidence
---

# 0005 - Parallel Agents: prerequisite gate and dependency plan

## Status

**Blocked at the prerequisite gate, reassessed 2026-09-06.** This is the
architecture decision and dependency plan requested when a prerequisite is
absent. No runtime, Settings, API, UI, or test implementation changes are made.
Ordinary single-Agent Turns continue unchanged.

The decision to withhold concurrency stands. The future topology and numeric
limits below are **proposed, not operator-approved or implemented**. Approval of
this record and executable closure of its dependencies are required before
delegation runtime work. The request to assess this feature is not a waiver.

This revision replaces the 2026-09-03 claims that Docker and Terminal isolation
are absent and that additional Runspaces alone establish child isolation. The
historical Runspace measurements below remain observations, not security or
performance guarantees for the proposed process topology.

## The gate

**Prerequisite work update, 2026-09-06:** the operator approved the focused
single-child V2 design in [decision 0009](0009-single-child-isolation.md), not
the two-child topology below. Private Tool storage/lifecycle components and an
explicit child-start refusal now exist. The complete child Engine profile,
per-child approvals, hard request admission, authenticated live proof, and
clean-install Engine support remain open; independent review returned request
changes. D1/D2 are therefore not closed and parallel scheduling remains blocked.

**Reassessment baseline:** DeskPilot `275cd6b` and tracked ShellPilot
`d1e1e139d0762ace9a3d2aa9ebd013a8c4235e84`.
The current request does not approve the two-child topology or authorize
completion of its prerequisites within this task. Only this decision and
routed Memory Bank records change; no runtime gate is relaxed.

`.github/prompts/implement-parallel-agents.prompt.md`:

> Confirm per-call approval and an appropriate isolation mechanism are shipped
> and tested. If either is absent, stop after writing an architecture decision
> and dependency plan. Do not add concurrency to the current shared Engine
> Runspace or shared writable Project state.

**Terminal approval: locally implemented and tested, conditionally usable.**
`Initialize-DpTerminalTool` requires the Engine's disabled-built-in dispatch
refusal. The focused approval suite currently passes **65 tests, zero failures,
zero skips**, using Pester 5.7.1 and staged ShellPilot 0.4.1. It exercises actual
`Invoke-Shp` dispatch with scripted provider responses and inert executors,
including a positive native-execution control and rejection of an older Engine.
It is not live Model acceptance or a clean-install distribution proof.

Local `perCallApproval` still defaults off; Isolated Terminal requires approval
independently. Native File writes and MCP calls are not covered by this bridge.
A child needs its own bridge and enforced Tool policy, not an inherited grant.

**Appropriate child isolation: partial components, no runnable child profile.**
Docker Desktop/WSL2, optional Terminal isolation, and private child Tool storage
exist. Decision 0009 retains 87 passing component tests, including 19 actual
container cases, and a full DeskPilot gate with 2,373 passes, zero failures, and
five existing browser skips. These are retained results, not new runs for this
assessment, and do not establish a complete child Agent. In particular:

- `New-DpTurnParameter` leaves native File Tools enabled when File Permission
   is on, even when Terminal is Isolated. Workspace Folder is not confinement.
- `TerminalSession` bind-mounts the selected Project itself. Its read-write
   mode has no total Project disk quota and no child-specific change isolation.
- No child execution profile combines isolated histories, Tools, credentials,
   Project storage, approvals, lifecycle, and aggregate quotas.
- `Get-DpChildReadiness` always returns `ready = false`, even when
  `childExecution.enabled` is true. The `startChildRun` operation refuses with
  `403 child_profile_disabled`, `503 child_profile_unavailable`, or `409 busy`.
  Existing tests explicitly require no container launch or ordinary Turn
  fallback. An enabled Setting or a prepared Tool image is not readiness.

The missing boundary is therefore **child Agent isolation**, not the presence
of a container runtime. A read-only Terminal mount cannot close it while other
enabled Tools retain host access. An obtainable enforcing Engine and live
authentication remain separately unverified release dependencies; no current
Gallery availability claim is made without a fresh distribution check.

### Remaining prerequisite work

The readiness helper's missing contracts map to concrete dependency work. None
is satisfied by adding another Engine Runspace or raising `maxChildren`.

| Missing contract or gate | Dependency | Required next evidence |
| --- | --- | --- |
| `engine-request-admission` | D1 | Complete-request token bounds and Engine-priced reservations before dispatch, including failed/unknown Usage and all resends; obtainable supported Engine contract. |
| `child-engine-process` | D2 | The approved V2 credentialless Engine container and separate trusted provider transport integrated with the Host Server, not only a Tool container. |
| `child-approval-bridge` | D2 | Per-child prepare/approve/dispatch with generation, policy and exact-action binding, revocation and cancellation; no inherited grants. |
| `complete-run-resource-limits` | D2 | Combined limits across both containers and trusted transport, independent Stop/lease, Host Server restart reconciliation, and retention age enforcement. |
| `authenticated-live-proof` and open security findings | D1/D2 | Clean, non-sensitive whole-child proof; resolve the two remaining Major acceptance gates and obtain independent review of the credential-filter correction. |
| Two-child topology approval | D3 | Explicit operator approval of this proposal after the prerequisite contracts and isolation evidence are available. V2 approves one child only. |

Complete the approved single-child prerequisite first. Its File/Terminal-only,
network-disabled profile does not yet provide public-evidence retrieval: before
that child type is admitted, D2 also needs a separately approved and tested
public-only context and governed retrieval profile. Do not enable native
Browsing, MCP, ambient credentials, or general Tool egress to satisfy the use
case. No prerequisite implementation or new profile approval is recorded here.

## Engine state and historical measurements

The current controlling path is `Initialize-DpEngine` creating one Engine
Runspace and `Invoke-DpTurn` binding every Turn's pipeline to
`$script:DeskPilot.Engine.Runspace`. The staged Engine source exposes batch
concurrency, but no parent/child lifecycle or delegated-approval contract was
found. This is a source finding for the inspected artifact, not a claim about
future Engine releases.

On 2026-09-03, three separate Runspaces were opened in one process, ShellPilot
was imported into each, and a Tool plus a global variable were registered in
the first only:

| Observation | Result |
| --- | --- |
| `Get-ShpTool` in runspace 1 / 2 / 3 | `probe_thing` / empty / empty |
| `$global:DeskPilotProbeRoot` in runspace 1 / 2 / 3 | `ONLY-IN-RS1` / empty / empty |
| `$PWD` set per runspace | held independently |
| Import cost | **752 ms** first, then **21 ms** and **17 ms** |
| Managed heap, three imports | **15 MB** total |

The Tool table, Runspace globals, and PowerShell location were independent.
That does not isolate the process environment, filesystem, credentials, or
mutable objects passed by reference. These measurements do not estimate the
cost of a contained child process and do not prove that the existing Tool
reconcilers can be reused unchanged.

## Verified Engine batch contract

The earlier assessment inspected staged ShellPilot 0.4.1. This reassessment
re-read `Invoke-ShpBatch` and `Invoke-ShpBatchItem` from tracked Engine commit
`d1e1e13`: the batch still exposes `ThrottleLimit` from 1 through 64, default 4,
and delegates execution to `Invoke-ShpParallel`, also inspected, which uses
`ForEach-Object -Parallel`. Each item returns a `ShellPilot.BatchResult` with
identity, status, Usage, cost, iterations, duration, and error; Usage records
are merged into the caller's Engine Usage store after a synchronous batch.
With `AsJob`, those records stay in the job's Engine Usage store instead. This
source check establishes the local batch contract, not released child support.

The current batch bootstrap is not a supported DeskPilot delegation mechanism:

| Contract | Source symbol | Consequence for a child |
| --- | --- | --- |
| `DisableUserPrompts = $true` | `Invoke-ShpBatch` | Native Ask-User is unavailable; this alone does not disable a separately injected approval bridge. |
| `DisableProgressEvents = $true` | `Invoke-ShpBatch` | No structured live Tool Activity for DeskPilot's stream classifier. |
| `DisableStreaming = $true` | `Invoke-ShpBatch` | No child answer deltas. |
| `History = @()` | `Invoke-ShpBatchItem` | No caller-supplied replay history. Minimum task context could still be supplied as prompt data. |
| One shared invocation parameter set | `Invoke-ShpBatch` | Entries consume Prompt and Id, not independent Agent, Model, Tool, or Permission descriptors. |
| Re-register User Tools by command name | `Invoke-ShpBatchItem` | DeskPilot's injected backing commands are not imported into the new Runspace; failed registrations are warned and skipped. |
| MCP attachments are not replayed | `Invoke-ShpBatch` | No supported shared MCP lifecycle. |
| Check completed spend before dispatch | `Invoke-ShpBatchItem` | `MaxBatchBudgetUSD` is not a hard aggregate cap: in-flight calls can still be billed. |

The batch's `AsJob` option changes how the caller receives its work; it does not
add child policy, approval, progress, or descendant-cancellation contracts.

Missing `run_terminal_command` does not justify restoring native Terminal.
The required profile must refuse to start when an owned Tool or its bridge is
missing, and independently refuse dispatch of disabled native Tools. The batch
can copy authentication context and Tool-policy objects; that is not proof of
separate child credentials or immutable policy ownership.

Use the Engine for provider transport and Usage, not as an assumed orchestration
contract. Do not patch the ignored dependency in place to manufacture support.

## What is actually shared, and therefore actually needs a design

A second probe set two runspaces to two different working directories:

| State | Scope | Consequence |
| --- | --- | --- |
| `$PWD` (PowerShell location) | per runspace | fine |
| `[System.Environment]::CurrentDirectory` | process-global, last writer wins | **resolved 2026-09-03**: `Set-DpEngineLocation` no longer writes it, because no Tool reads it |
| Environment variables | **process-wide** | already recorded (2026-08-11, Engine Runspace environment divergence); still open |
| A child process spawned from a runspace | inherits that runspace's `$PWD`, not `[Environment]::CurrentDirectory` | measured: a child from runspace 1 reported runspace 1's folder while the process-global value pointed at runspace 2 |
| Engine OAuth token file | shared on disk in the current host integration | not a child credential boundary; never mount it into child Tool reach |
| MCP attachments | per runspace, started from that runspace's `$PWD` | a second Runspace would start its own third-party server processes |

The working-directory half was closed by measuring what actually reads the
process value. With `$PWD` pointed at folder A and
`[System.Environment]::CurrentDirectory` at folder B, `read_file`,
`list_directory`, `write_file` and `run_command` all resolved against **A** (the
written file physically landed in A), and ShellPilot starts an MCP server from
`(Get-Location).Path` as well. Only a raw `[System.IO.File]` call with a relative
path followed B, and neither DeskPilot nor the Engine makes one. The write was
therefore removed, with a paired regression test.

The environment block remains process-wide. Decision 0001 now constructs a
separate allow-listed environment for Terminal commands, not for additional
Engine Runspaces, File Tools, MCP, or arbitrary User Tools. A Runspace location
and a scratch Git working tree are neither credential nor filesystem isolation.

## Proposed topology and child state

Retain one Host Server and the ordinary parent Engine Runspace. For explicitly
selected delegation, propose at most two supervised child processes, each owning
one Engine Runspace, history, Tool registry, approval bridge, Usage records, and
OS-enforced execution boundary. Never run children on the parent's Runspace.

Separate processes are proposed for independent environment ownership and
termination. They add IPC and startup cost, which has not been measured. The
earlier same-process/multiple-Runspace proposal has lower integration overhead
but does not remove ambient process state; neither choice removes the need for
an OS-enforced Tool boundary. The current batch API cannot supply the missing
DeskPilot-owned bootstrap and lifecycle. These are proposal tradeoffs, not a
claim that secure in-process orchestration is impossible.

Process separation removes accidental process-environment sharing; it does not
by itself restrict filesystem or credential access. Every child-accessible Tool
must be contained, including reads and discovery Tools. Reuse Docker/WSL2 only
after that complete profile passes its own tests. No host home, token file,
control socket, SSH agent, ambient credentials, or shared writable mount may be
reachable. MCP and arbitrary User Tools are absent in the first slice.

Engine authentication and provider transport remain Engine-owned. A supported
explicit, scoped credential/bootstrap and Model-egress contract is a dependency,
not an implementation supplied by this decision. Do not mount the user's token
store or copy ambient tokens into every child as a substitute. Provider access
must not become general Tool network access.

The delegated parent Turn has three phases: tool-free planning, supervised child
execution, and tool-free synthesis. Children can progress independently; the
parent does not mutate the Project while they execute. This avoids needing to
resume a Tool-enabled parent with untrusted child output. Engine calls in all
three phases count toward the one visible Turn's budgets and Usage.

The Host Server is the sole writer of Conversation, pending-change, scheduling,
and Usage stores. Child processes return bounded data over separately owned,
authenticated IPC channels; they receive neither the Host Server session token
nor references to its mutable state. Bind each channel to its child outside the
payload, so a child cannot impersonate a sibling by changing an id.

Before launch, persist a versioned claim containing Host Server launch id,
Conversation id, parent Turn id, child id, attempt id, frozen policy digest,
Agent identity/body digest, Model, explicit task, Tool allow-list, Permission
subset, input provenance, budgets, deadline, storage identity, and lifecycle
state. Never persist credentials. A failed claim write prevents launch.

States are `queued`, `starting`, `running`, `waiting-approval`, `stopping`, then
one terminal outcome: `completed`, `failed`, `cancelled`, `timed-out`,
`limit-exceeded`, or `interrupted`. Keep cleanup status separate from outcome.
The Host Server owns transitions; a child's claimed success cannot certify
cleanup, Usage completeness, or an applied change.

## Scheduling, context, and authority

- Allocate at most two child identities over the entire parent Turn, not two
  per batch. Queue length is two, and queued/running/waiting children together
  never exceed two. Other Conversations, schedules, and Intercom prompts keep
  their existing single-Turn dispatcher. No recursive delegation is registered.
- Admit each child only after validating its task, Agent, Model, exact Tool
  set, Permission subset, context, iterations, Usage, duration, and storage.
  A child that cannot satisfy one limit does not start. No silent substitutions.
- Effective authority is the intersection of the parent's captured allowed
  authority, live Permissions, the requested subset, and the child profile.
  Later Settings cannot widen it. Revocation prevents subsequent dispatch and
  cancels affected waits. Validate individual Tool names as well as categories.
- Start from an empty, separately owned history. Pass only approved task data
  and selected input excerpts with source identity and content digests. Do not
  copy the parent's system prompt, full history, User Profile, Agent Memory,
  Attachments, Skill roots, or Instruction roots implicitly. The selected
  Agent's approved body is distinct from retrieved untrusted data.
- A public-evidence child's task and context may use only inputs the operator
  designated public. Model-authored task text derived from private parent data
  is private too. Reject that transfer unless a separate disclosure approval
  binds the exact payload. Do not infer public status through a content filter
  or from the child profile's name.
- Enforce context limits before every provider request, including system text,
  Tool schemas, replay history, retrieved text, and retries. Disable implicit
  discovery outside the selected input. Character estimates are not hard token
  bounds; require verified Engine counting or a conservative proven upper bound.
- Each child has a separate approval wait. Bind an answer to launch,
  Conversation, parent Turn, child, attempt, request, policy digest, and exact
  action fingerprint. Consume it once; reject stale, cross-child, changed-policy,
  and replayed answers. Approval can narrow but never override a denied Tool.

## Proposed server-side limits

These are proposed policy values, not Settings that exist today. Configuration
may lower a hard maximum, never raise it; child limits are additionally capped
by the parent's remaining reservation. Invalid or unsupported bounds refuse
delegation. All elapsed limits include queueing, approvals, and retries.

| Bound | Proposed default | Hard maximum |
| --- | --- | --- |
| Concurrent children / total child identities per parent Turn | 2 / 2 | 2 / 2 |
| Delegation depth / child queue length | 1 / 2 | 1 / 2 |
| Parent Turn duration / child duration | 600 s / 300 s | 900 s / 600 s |
| One approval wait / cancellation grace | 60 s / 5 s | 120 s / 10 s |
| Child input context per provider request | 16384 tokens | 32768 tokens |
| Parent input context per provider request | 32768 tokens | 65536 tokens |
| Child cumulative input plus output | 32768 tokens | 65536 tokens |
| Parent plus all children cumulative input plus output | 98304 tokens | 196608 tokens |
| Output per provider request | 4096 tokens | 8192 tokens |
| Tool iterations per child / aggregate | 8 / 32 | 16 / 64 |
| Usage cost per child / aggregate | USD 0.25 / USD 1.00 | USD 1.00 / USD 2.00 |
| Side-effect-free retries per child identity | 0 | 1 |
| Materialized child storage, including baseline and temporary files | 128 MiB | 256 MiB |
| Materialized storage for all children | 256 MiB | 512 MiB |
| Retained proposal and recovery data per parent / installation | 128 MiB / 512 MiB | 256 MiB / 1 GiB |
| Proposed files per child / aggregate | 200 / 400 | 1000 / 2000 |
| Unreviewed proposal retention | 24 hours | 7 days |
| Child process memory / CPU / processes | 1 GiB / 1 / 64 | 2 GiB / 2 / 64 |
| Child result / one event / retained events per child | 256 KiB / 16 KiB / 300 | 1 MiB / 64 KiB / 1000 |

Reserve worst-case provider input/output and Engine-reported pricing before
dispatch, atomically against child and aggregate balances. Count planning,
synthesis, failed attempts, provider retries, and all children. Engine transport
retries must consume reservations too; a Tool event or a completed-spend check
cannot enforce this. Unknown pricing or an unsupported reservation contract
blocks cost-bounded delegation. Unknown Usage remains unknown and retains its
reservation; never release it as zero to admit more work.

Retained-storage admission includes claims, manifests, before/after file bytes,
and recovery journals. Reserve recovery capacity before applying any file. An
unresolved journal cannot expire to free space; refuse new work when capacity
cannot be reserved. Keep existing Usage stores' retention policy separate.

The deadline ends work even if approvals or Tools hang. Quota exhaustion is a
structured terminal outcome, not silent truncation or a successful partial
result. Bound proposal manifests, file counts, IPC buffers, and Diagnostics
while constructing them. Stop draining child output into UI progress as soon
as cancellation begins; trusted cleanup and final Usage reconciliation remain
separate control operations before the parent terminal record is sealed.

## Project isolation and deterministic change review

Freeze selected Project input before any child starts, preserving the user's
existing uncommitted changes. Read-only children receive an immutable restricted
copy. Writable children receive independent quota-enforced filesystems, such as
bounded temporary-memory filesystems, seeded from that baseline. The quota must
include the seed and all temporary writes, not only exported changes.

Never give children a writable bind to the actual Project, sibling storage, or
shared Git metadata. A Git worktree alone is not confinement or a storage quota.
Refuse unsupported links, reparse points, special files, path aliases, and
baseline sizes. Project reads must not widen into a containing Git repository.

Return proposed files separately from child prose. A bounded manifest carries
Project-relative path, operation, baseline digest, resulting digest, size,
binary/text type, and child/attempt provenance. The Host Server independently
checks bytes, paths, links, and quotas. Child-provided command strings, absolute
paths, Git hooks, filters, or merge drivers never become host operations.

Combine proposals in stable child-id and canonical-path order. Equal resulting
bytes can be deduplicated with both sources retained; incompatible edits,
delete/modify pairs, renames, binary alternatives, case aliases, and overlapping
paths are conflicts regardless of arrival order. No last-writer-wins behavior.

Show one combined proposal before any Project write. Existing Keep only accepts
already-applied pending changes and cannot be reused as an implicit apply action.
Require explicit apply approval bound to the exact combined manifest. Rejection
writes nothing. Resolve conflicts through a reviewed Merge Plan or explicit
binary choice, not automatically through a Tool-enabled Agent.

Before applying, take a pre-apply snapshot and journal, acquire exclusive
DeskPilot Project mutation ownership, and recheck each baseline/current digest.
An outside edit invalidates the preview instead of being overwritten. The file
replacement protocol must prevent a check/write race; where the platform cannot
enforce the required ownership or conditional replacement, refuse application.
Do not advertise that an in-process lock excludes external editors.

Apply the reviewed set deterministically without touching the user's Git index
or Branch. Only successfully applied files enter parent Activity, pending
changes, Undo, and Checkpoint ownership. Rejected child proposals are not
`filesWritten` in the real Project. On failure or restart, recover from the
journal; restore only bytes still matching this operation's recorded writes.
If recovery would overwrite a later user edit, stop and report manual recovery.
The parent cannot complete while a partial apply or unresolved cleanup exists.

## Results, Activity, Usage, and Intercom

Use a versioned result envelope with launch/Conversation/parent/child/attempt
identity, sequence, status, Agent, Model, bounded findings, source provenance,
Activity, Engine Usage with completeness/pricing flags, proposal manifest, and
cleanup outcome. Accept it only from its bound channel and active generation.
Reject duplicate, stale, oversized, out-of-order, and cross-child records.

Sequence each child independently; assign an additional Host Server sequence
when events are accepted. Ordering claims describe receipt, not a fictitious
total execution order. Retain child evidence while showing one parent Turn with
expandable child progress and aggregate Usage. Count a completed parent as one
user-visible Turn, not three; do not add child Usage twice through both the
parent Message and global counters. Unknown or partial values remain labeled.

Child prose is untrusted data, never a system prompt, Tool call, or executable
instruction. Validate structure and encode output. Tool-free parent synthesis
is the enforcement boundary; an injection label alone is not. Rendering child
evidence must not fetch remote images, execute HTML/SVG, or turn child paths
into privileged file actions. Children cannot update Agent Memory or global
Customizations, and delegated parent results are excluded from automatic Memory
learning. Persisting child findings as Memory requires a separate user decision.
A later Tool-enabled action requires a new explicit user Turn.

Intercom reports Host Server-authored parent status, child counts, and a
Conversation link back to DeskPilot. Never forward child prose, raw arguments,
paths, credentials, or arbitrary child-authored links. Multi-child approvals
and combined change review occur in DeskPilot; phone replies cannot authorize
a child action in this slice. Stop retains its existing operator authority and
cancels the whole parent Turn.

Diagnostics reports child lifecycle state, orphan ownership and cleanup status,
queue depth, reserved versus reported Usage, remaining aggregate limits, and
bounded refusal/error codes. Host Server log and Support bundle records are
constructed from allow-listed fields, never raw child state, prompts, file
content, arguments, credentials, or environment values. A healthy Terminal
runtime alone must not report child delegation as ready.

## Cancellation, recovery, and rollback

Stop first closes admission and invalidates the generation, then cancels every
approval wait and provider request and terminates all owned child processes,
Tool descendants, and execution environments. Use an independent control path,
not a second pipeline on a busy Engine Runspace. Verify absence before emitting
the final stopped record. Cleanup failure stays visible and blocks further
delegation; do not report successful cancellation while descendants remain.

A child failure may leave sibling work running within existing reservations,
but the parent must report the partial outcome and never auto-apply its changes.
Retry only with evidence of no Tool dispatch, no response, and no external
effect, within the same child identity's original deadlines and quotas. Unknown
effects forbid retry. Use a fresh attempt id and fresh isolated state; retain
failed-attempt Usage and invalidate all older approvals/results.

On Host Server restart, reconcile persisted claims before enabling delegation.
Treat unfinished attempts as interrupted, never automatically replay them.
Identify owned resources by installation, launch, parent, child, and attempt
identity plus process start time or immutable container id, not PID alone.
Independent leases must stop descendants if the Host Server dies. Stop or
recover orphan resources; refuse new work when ownership or cleanup is uncertain.
Existing single-Agent behavior must not depend on child infrastructure readiness.

Rollback disables new delegation, cancels and verifies existing children, and
retains attributable Usage, evidence, and recoverable apply journals. Remove
only owned expired child/proposal data, with visible expiry; never silently
discard a reviewed apply journal or Checkpoint reference. Restore applied
Project files only through the recorded, conflict-aware recovery path. Do not
uninstall shared Docker/WSL2 or change Local/Isolated Settings as rollback.

## Threat model for each child and the parent

Assume every retrieved file, page, Tool result, and child result is hostile.
Evaluate the lethal trifecta against the context the caller already knows,
not just the data stored inside its Tools.

| Execution profile | Private data | Untrusted content | Removed or restricted outbound authority |
| --- | --- | --- | --- |
| Internal-source child | Only selected Project input | File contents and Tool results | No general Browsing, browser, MCP, Intercom, or Terminal egress; only the approved Engine provider transport. |
| Public-evidence child | No internal excerpts, parent history, Memory, or credentials | Public pages | Governed public retrieval; no private mounts or private parent context. |
| Parent synthesis | Approved child findings | All child output | Every executable Tool disabled; no automatic remote rendering or child-content Intercom forwarding. |
| Trusted apply operation | Exact approved manifest and baseline | Child file bytes and names | No network or interpretation of child bytes as commands; conditional, path-confined writes only. |

An internal child with arbitrary outbound access is refused, even if its task
says to be careful. An allow-listed host is not data-loss prevention: a selected
origin can still receive encoded private content. Any mixed private/public
profile needs a separately approved, tested disclosure policy; it is not granted
by a parent Permission alone. Engine provider transport is an explicit trusted
data-processing boundary, not permission for Tools to call arbitrary endpoints.

## Dependency plan and approval gates

| Order | Owner | Required deliverable | Exit evidence |
| --- | --- | --- | --- |
| D1 | Engine maintainers and DeskPilot | Obtainable enforcing Engine; verified per-request Tool dispatch, event, exact-context, retry, Usage-reservation, and scoped authentication contracts. | Clean-install positive/negative contract tests; no ignored local patch as the only source; unknown capabilities fail closed. |
| D2 | DeskPilot isolation implementation | Complete single-child execution profile with confined reads/writes, no ambient credentials, default-deny Tool egress, real storage quota, independent lease, and verified cleanup. | Actual runtime hostile-workload tests, including sibling/host paths, quota exhaustion, aliases, control sockets, credential canaries, and host death; no skipped controls. |
| D3 | Operator | Approve this revised process topology, limits, credential design, Project apply semantics, dependency cost, and remaining risks after D1/D2 design details are resolved. | Dated approval recorded here. Prior Terminal approval is not approval of child isolation. |
| D4 | DeskPilot implementation | Owned child lifecycle, bounded IPC, separate histories and bridges, atomic reservations, server-authoritative scheduling, and restart reconciliation. | Test-first proofs for two independent children, all child/aggregate bounds, stale/cross-child events and approvals, cancellation races, retries, and orphans. |
| D5 | DeskPilot implementation | Quota-backed input/work areas and deterministic combined proposal review, conditional apply, journal recovery, Undo, and Checkpoints. | Conflicting and rejected proposals write nothing; user edits survive; partial apply, restart, conflict, and rollback tests pass on supported platforms. |
| D6 | DeskPilot implementation | Parent Turn UI, attributable Activity/Usage, Intercom status, and structurally redacted Diagnostics. | API and desktop/mobile end-to-end tests; correct totals, unknown Usage labels, safe rendering, bounded events, and no progress after final Stop. |
| D7 | Maintainer and independent security reviewer | Release readiness with all specifications and operational recovery documentation aligned to the approved implementation. | Full suite, ordering/race stress tests, clean live non-sensitive Project proof, and independent security review with every Blocker/Major resolved. |

D1/D2 prerequisites require separately scoped work; this assessment does not
implement them. Do not begin D4 until both mechanisms are shipped/tested and D3
is explicitly approved. Enabling native File or MCP behavior outside the owned
child profile additionally requires the pre-dispatch contract in
[specification 120](../../specs/120-per-call-approval-engine-contract.md).

The first implementation tests must cover permission escalation, two histories
and Tool registries, concurrent attempts against one Project, malicious child
output, aggregate overspend, approval substitution, Stop during each lifecycle
transition, timeout, partial failure, side-effectful retry refusal, restart,
orphan cleanup, merge conflict/rejection/recovery, and Usage deduplication.
Use barriers and injected clocks for ordering tests, plus real-runtime stress
and positive/negative controls. No product code precedes a relevant failing test.

At D7, update requirements, architecture, API contract, UI design, security model,
and roadmap together. No new runtime contract or shipped-feature claim is added
to those specifications while the topology is unapproved and the gate is closed.

## Evidence and limitations

The fresh gate assessment uses DeskPilot `275cd6b` and tracked Engine `d1e1e13`.
Its controlling sources are
[child readiness](../../source/Private/Get-DpChildReadiness.ps1) and the
[policy and refusal tests](../../tests/Unit/ChildAgentIsolation.Tests.ps1).
The approved single-child design, retained component/full-suite evidence, and
unresolved review findings remain in [decision 0009](0009-single-child-isolation.md).
No complete child, two-child ordering/stress run, or authenticated live proof
was executed for this reassessment. The failed prerequisite gate prevents those
downstream acceptance claims; documentation validation cannot substitute for
them. Runtime specifications already describe the closed gate and stay unchanged.

Fresh focused verification completed **2026-09-06 12:03:03 UTC**: **93 passed,
zero failures, skips, or unrun cases**, using PowerShell 7.6.5 and Pester 5.7.1.
This comprises 65 Terminal approval cases and 28 child policy/readiness/refusal
cases. It uses real Engine dispatch with scripted provider responses and inert
executors, not live Model calls or child containers. The detached process exited
0 and the recorded controlling source/test hashes still match. These tests
confirm the closed gate, not enforcement by an executing child profile.

Fresh local evidence is retained under `$env:TEMP` in
`deskpilot-parallel-gate-830ef0e10b9a45f6a69bc86f86ba4811`: the full
`focused-tests.log`, `focused-tests.xml`, `focused-tests.json`, completion
marker, native Markdown render, and `decision-validation.json`. These are local
artifacts, not published evidence. The frozen reviewed document hashes are in
`review-validation.json`; final checks are in `final-validation.json`.

Independent documentation review returned **approve**, with zero Blockers,
Majors, or Minors and one evidence-attribution Nit. The report is retained as
`review-report.md`, bound to `review.diff` in that same directory. The Nit was
corrected by removing the linked Engine worktree cleanliness claim, rather
than claiming a retained status artifact that the bundle did not contain.
That correction is author-verified, not independently re-reviewed. Approval
covers the reviewed documentation only: V2's unfinished runtime, its prior
findings, and the proposed two-child topology are not approved by this review.

The following approval evidence and review artifacts belong to the earlier
assessment, not a fresh review of this revision. Its baseline was DeskPilot
`9d8211b`, implementation `f6af6fd`. The staged ShellPilot 0.4.1 module inspected
and used for dispatch tests has SHA-256
`1AB55A06244ED302ECAA5B394CF1487DF815EE0237360474178C4BEEAC3DA368`.

| Evidence | Controlling source or retained record |
| --- | --- |
| Single Engine Runspace and per-Turn binding | [Initialize-DpEngine](../../source/Private/Initialize-DpEngine.ps1), [Invoke-DpTurn](../../source/Private/Invoke-DpTurn.ps1). |
| Isolated Terminal does not disable native File access | [New-DpTurnParameter](../../source/Private/New-DpTurnParameter.ps1). |
| Direct Project bind and bounded temporary storage, not Project quota | [TerminalSession](../../source/isolation/TerminalSession.cs), [operator limits](../../docs/isolated-terminal.md). |
| Current approval proof: 65 passed, zero failures/skips, Pester 5.7.1 | [TerminalApproval tests](../../tests/Unit/TerminalApproval.Tests.ps1); real Engine dispatch, scripted provider, inert executors. |
| Earlier Docker, full-suite, UI, and review evidence | [decision 0001](0001-isolated-tool-execution.md); retained, not rerun here. |
| Approval ownership and remaining native File/MCP dependency | [decision 0008](0008-per-call-approval.md), [security model](../../specs/050-security-model.md). |

Pester 5.7.1 was reused from its existing temporary staging directory; it is not
currently on the default module path. No dependency was installed or replaced.
The first verification wrapper expected the older 63-case count and reported
failure despite 65 passing tests; the corrected wrapper requires all 65 current
cases, no failures, no skips, and no unrun tests.

The corrected run completed at 07:15 UTC with exit code 0. The local log and
NUnit XML use the temporary artifact suffix
`ca9a190975b2463c9e0b327bce246bbd`; they are not published or committed.

Specification 120 remains a proposed native File/MCP callback, not proof of
current dispatch enforcement. Its older Terminal name and 0.4.0 dispatch claims
are superseded by decision 0008 and the executable dispatch tests above.

No executable verification is required for these Markdown edits; retained
native rendering, local link resolution, and scope evidence validate the
documentation and the existing prerequisite approval, not a child runtime.
An independent security review completed 2026-09-06 and returned request
changes: zero Blockers, one Major review-state inconsistency, and one Minor
missing retained Markdown artifact. These documentation findings are addressed
by the explicit, artifact-bound review state and the retained validation
record; the corrections are author-verified and no second independent review or
operator topology approval occurred in that earlier assessment. The current
documentation review above is a separate, artifact-bound assessment.

The reviewer report and the retained validation basenames exist under
`$env:TEMP` as local, uncommitted evidence:

- `deskpilot-parallel-review-ca9a190975b2463c9e0b327bce246bbd-report.md`
- `deskpilot-parallel-review-ca9a190975b2463c9e0b327bce246bbd-validation.json`

Do not interpret these artifacts as reviewer approval of the fixes. Preserve
that full delegation/stress/live proof, credential isolation, quota
enforcement, and transactional apply remain unproven; no remote operation,
publication, authentication change, or production Settings change is
authorized or performed by this assessment.
