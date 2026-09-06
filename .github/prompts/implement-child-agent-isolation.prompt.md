---
description: "Implement single-child Agent isolation and quota-bounded work areas before parallel delegation"
agent: "software-engineer"
---

# Implement child Agent isolation

Build and prove the missing isolation prerequisite for
[parallel Agents](implement-parallel-agents.prompt.md). Deliver one complete
child execution profile and private, quota-bounded writable storage. Do not
implement parallel scheduling in this task.

## Scope and approval

- Missing child isolation and storage quotas are the work to implement, not a
  prerequisite that must already exist. Do not repeat the parallel-Agents
  prompt's stop-at-design gate merely because these mechanisms are absent.
- Start with one child at a time through an explicit Host Server operation or
  checked-in proof harness. Keep the parent Engine Runspace idle while that
  child runs. Do not enable recursive delegation or shared writable execution.
- Treat decision 0005's topology and numbers as proposed, not approved. Present
  a focused single-child design covering containment, Engine integration,
  credentials, network, quotas, approvals, lifecycle, export, and recovery.
  Obtain explicit operator approval before runtime edits. This approval covers
  the prerequisite slice only, not the later two-child delegation design.
- Once approved, implement and validate incrementally. Do not call a design-only
  result complete. Escalate concrete missing access or unsupported external
  contracts with evidence; do not weaken a boundary to continue.

## Required context

Read the routed Memory Bank and these records:

- [Parallel Agents decision and dependencies](../../.memory-bank/decisions/0005-parallel-agents.md).
- [Existing Terminal isolation](../../.memory-bank/decisions/0001-isolated-tool-execution.md),
  [Terminal approval](../../.memory-bank/decisions/0008-per-call-approval.md),
  and the [isolation guide](../../docs/isolated-terminal.md).
- [Architecture](../../specs/020-architecture.md),
  [security model](../../specs/050-security-model.md), and the relevant sections
  of requirements, API contract, UI design, and
  [remaining Engine approval contract](../../specs/120-per-call-approval-engine-contract.md).

Start source inspection at
[Engine initialization](../../source/Private/Initialize-DpEngine.ps1),
[Turn parameters](../../source/Private/New-DpTurnParameter.ps1),
[Turn execution](../../source/Private/Invoke-DpTurn.ps1), and
[Terminal containment](../../source/isolation/TerminalSession.cs).
Reuse the adjacent approval and isolation tests. Reverify current source,
dependencies, capabilities, and test outcomes instead of assuming old versions,
counts, or release availability remain current.

Terminal containment does not confine native File Tools. Separate Runspaces
isolate their globals, not the process environment or filesystem. A Git
worktree is not a security boundary or a disk quota. `Invoke-ShpBatch` is not a
drop-in child lifecycle, approval, or hard aggregate-budget contract.

## Required execution boundary

- Use an independently owned child process and Engine Runspace with a tested
  OS-enforced Tool boundary. Prefer the existing Docker Desktop/WSL2 dependency
  where suitable; obtain approval for new dependencies, host privileges, or
  topology changes. Do not claim process separation alone provides confinement.
- Support confined File reads and writes plus approved Terminal execution in
  the child's work area. Disable every other capability in this first profile:
  general Browsing, browser automation, MCP, arbitrary User Tools, and delegation.
  Disable or contain Skill/Instruction discovery and native Vision path reads.
  No child-accessible Tool may escape through a host implementation.
- Prove native disabled-Tool dispatch is refused. Register only the owned Tools
  the profile permits. Missing approval or containment support refuses child
  startup; never restore native host execution or fall back to Local.
- Give each run its own task, Agent body, Model, frozen policy, minimum selected
  context, history, Tool registry, approval bridge, Activity, Usage, and deadline.
  Repeated runs must not inherit each other's state. Child authority can only
  narrow the parent's captured authority and live Permissions.
- Do not inherit the ambient environment, home, token stores, SSH agents,
  credential caches, host control sockets, or Host Server session token. Keep
  Engine credentials outside File and Terminal reach, including environment,
  process inspection, and child output. Use Engine-owned transport/authentication
  through a verified supported boundary; do not reimplement provider calls.
- Deny Tool network egress by default, including DNS, direct sockets, IPv6,
  metadata services, host aliases, and loopback control endpoints. Any required
  Engine provider channel must be independent of general Tool network access.
  An allowed hostname alone is not credential isolation or data-loss prevention.
- Apply the lethal-trifecta test to the child's context as well as its Tools.
  Label files, retrieved context, and results as untrusted data. Do not copy the
  parent's full history, User Profile, Agent Memory, or Customization roots.

## Quota-bounded work areas

- Capture a bounded, consistent selected Project baseline, including selected
  uncommitted input, without changing the user's files, index, or Branch. Refuse
  an oversized or unstable baseline; do not silently omit files or widen scope
  to the enclosing repository. Exclude shared Git metadata and credential files.
- Provide a read-only profile and a separately granted writable profile. Each
  writable run owns a distinct filesystem seeded from the baseline. Never
  mount the real Project or another run's storage read-write.
- Enforce a hard storage quota below the Model, with explicit byte and file-count
  limits. Count seeded input, writes, temporary data, output, export staging,
  and retained proposals. Bound installation-wide retention too. Agree numeric
  defaults and hard maxima in the approved design, using decision 0005 as input.
- A directory-size poll, output cap, post-run rejection, or `/tmp` limit beside
  an unbounded writable Project mount is insufficient. Refuse startup on a
  platform or storage driver that cannot enforce the promised bound.
- Reject traversal, junctions, symlinks, hard-link escapes, reparse points,
  alternate streams, special files, nested mounts, and archive escape paths at
  input and export boundaries. Prevent path-swap races, not just lexical escapes.
- Export bounded proposed changes with relative paths, operations, sizes,
  baseline/result digests, and run provenance. The Host Server validates actual
  bytes, not just child-supplied metadata. Do not apply proposals to the real
  Project in this slice or mark them as real Project `filesWritten`.

## Approval, limits, and lifecycle

- Bind every non-routine command approval to the Conversation, parent Turn,
  child, attempt, request, policy, and exact action. Block before execution;
  denial, timeout, stale/replayed answers, or Permission revocation run nothing.
  Use separate waits, no inherited or Turn-wide grants, and no child approvals
  through Intercom in this slice.
- Enforce duration, CPU, memory, processes, output, context, iterations, and
  Usage limits across the complete run, including initialization and retries.
  Reserve before provider dispatch using verified Engine accounting/counting
  contracts; retain failed Usage and label unknown values. A check of completed
  spend is not a hard cap. Start with automatic retries disabled.
- Persist an ownership claim before launch and use bounded, authenticated,
  per-run IPC. Bind identities outside child-controlled payloads and reject
  stale, duplicate, oversized, or cross-run records. Keep the Host Server the
  sole writer of durable Conversation and Usage state.
- Stop cancels approvals and provider work, terminates all descendants and
  containers, and verifies cleanup through a control path that works while the
  child is busy. An independent lease must stop execution after Host Server
  death. Restart marks unfinished work interrupted, never automatically reruns
  it, and reconciles positively identified orphans before admitting another run.
- Cleanup failure is visible and blocks further child work. Do not report a
  final successful Stop while descendants remain or accept later child progress.
  Retain bounded failure evidence without secrets; never use global cleanup.
- Return structured status, provenance, Activity, Engine Usage, proposal data,
  and cleanup outcome. Child prose must not trigger Host Server or parent Tools,
  automatic Memory learning, remote image loads, or Intercom forwarding. Any
  optional synthesis is tool-free.
- Provide Diagnostics for profile readiness, effective limits, ownership, quota
  exhaustion, and cleanup. Setup and cleanup are explicit actions, not hidden
  Self-check mutations. Removing this runtime leaves ordinary Turns and shared
  Docker/WSL2 dependencies unchanged.

## Engine dependency handling

Verify the actual Engine dispatch, credential, context, retry, cancellation,
and Usage contracts from source or current primary documentation. Distinguish
implemented, tested, locally staged, and obtainable on a clean installation.

Implement supported DeskPilot adapters in tracked source. If an upstream change
is genuinely required, identify the exact missing contract, a minimal reproducer,
and the smallest upstream change; request permission before editing another
repository. Do not patch ignored dependencies or present a local fixture as a
released Engine. Independent storage/lifecycle work can continue while a live
Engine check is blocked, but the complete prerequisite remains incomplete.

## Test-first proof

Write a failing test before each behavior change. Verify actual effects, not
Tool schemas or source-string matches. Cover:

- Sequential runs with distinct histories, policies, Tool state, credentials,
  and files; one run cannot access another's data or approvals.
- Positive confined File/Terminal work, plus real attempts to read/write host
  paths, access control sockets, leak credential canaries, and bypass egress.
- Read-only denial; actual writable-quota exhaustion through File and Terminal;
  seed, temporary, inode/file-count, archive, and export/retention bounds.
- Approval pending, allowed, denied, expired, revoked, replayed, and cancelled;
  native disabled Tools cannot bypass the owned implementation.
- Stop during startup, approval, execution, and export; crashes, timeouts,
  Host Server death/restart, orphan cleanup, failed cleanup, and late events.
- Honest successful/failed/unknown Usage, limit enforcement, malicious output,
  unchanged real Project bytes and Git index, and ordinary single-Agent Turns.

Keep deterministic provider fixtures separate from authenticated live proof.
Run focused checks after each edit, the full suite for the completed boundary,
and a clean actual-runtime proof using bounded non-sensitive Projects. Retain
commands, versions, effective limits, logs, results, and verified cleanup. A
skipped control or an unavailable live sign-in is an open gate, not a pass.

## Definition of done

- Deliver tracked reusable implementation and a reproducible single-child proof
  entry point; a design, mock-only controller, or Terminal-only container is not
  completion of this prerequisite.
- Update the focused decision, relevant specifications, setup/recovery guide,
  changelog, and routed Memory Bank with demonstrated guarantees and limitations.
- Complete an independent security review and resolve every Blocker and Major
  before release. This prompt explicitly requests that review.
- Leave existing single-Agent behavior unchanged and optional child support off
  by default. Do not publish a runtime readiness claim without its evidence.
- Report separately: design approval, implementation, deterministic tests,
  actual-runtime tests, authenticated live proof, clean-install Engine support,
  and remaining parallel-Agents dependencies. Do not say parallel Agents shipped.
- Commit on a focused topic branch. Do not push or mutate a remote.

## Non-goals

Parallel scheduling, two concurrent children, recursive delegation, multi-child
UI, public-evidence browsing, MCP, new provider protocols, applying proposals to
the real Project, merge/conflict resolution, and changing normal Turn defaults.
Keep those follow-ups in the parallel-Agents dependency plan.
