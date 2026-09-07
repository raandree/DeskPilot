---
schema-version: 1
status: accepted
owner: software-engineer
last-verified: 2026-09-06
source: explicit operator approval of revised design V2 and local probes
---

# 0009 - Single-child Agent isolation

This record covers the prerequisite for parallel Agents, not parallel scheduling.
It records the approved design separately from demonstrated runtime guarantees.

## Approval and scope

On 2026-09-06 the operator declined the first proposal and requested revisions to
containment, credentials, approvals, lifecycle, and Host Server integration. The
operator then explicitly selected **Approve V2 for test-first implementation**
and **Approve this limited Engine contract expansion**.

V2 places the child Engine in a credentialless, network-disabled container and
uses a separate trusted Engine transport process. It includes explicit Host
Server integration instead of a proof-only controller. The permission covers
the smallest tracked ShellPilot changes for transport separation, pre-request
admission, counting and reservations, cancellation, and zero automatic retries.
It does not authorize new shared dependencies, host elevation, provider
protocols, publishing, remote mutation, or changes to ordinary Turn defaults.

DeskPilot implementation starts from `2d86925` on `ai/child-agent-isolation`.
ShellPilot has an unrelated modified test on `ai/edit-file-tool`; preserve it.
Authorized Engine work uses a linked worktree on `ai/child-provider-boundary`,
starting from `3446e32`, without switching or modifying the original worktree.

Approval covers one child at a time, private proposals, and no recursive
delegation. It does not approve decision 0005's two-child topology or applying
proposals to the real Project. Child support remains off by default.

On 2026-09-06, during the admission continuation, the operator chose **Keep V2
unchanged; close out verified groundwork** after the complete-request counting
gap was rechecked. Conditional Engine reservations can be implemented and
reviewed, but a fixture counter or a token estimate cannot satisfy the approved
bound. Complete integration and authenticated live proof remain open. This
decision does not weaken any numeric limit or authorize child startup.

The later [accepted budget amendment](0010-child-budget-estimates.md) authorizes
single-child V3 with explicit estimated provider budgets and unchanged isolation
boundaries. V2 and strict Engine admission keep their original meaning; V3
requires its own implementation, proof, and explicit opt-in.

## Boundary and Engine integration

The Host Server retains the ordinary parent Engine Runspace, which stays idle
for the complete child run. Active-Turn admission is acquired before baseline
capture and excludes ordinary Turns, schedules, helpers, and another child.

The child owns one fresh process and Engine Runspace, task, approved Agent body,
Model, empty history, frozen policy, Tool registry, deadline, and Usage. Nothing
is reused between runs. Only owned File and Terminal adapters are registered.
Native File, Terminal, Browsing, Ask-User, Task List, MCP, arbitrary User Tools,
browser automation, Skill/Instruction discovery, Vision, and delegation are
unavailable. Test native dispatch refusal, not just schema omission.

The Engine container and Tool container use separate process and mount
namespaces, no host mounts, no host control sockets, a read-only image, and
Docker's `none` network. Tool processes are non-root, have no capabilities,
cannot acquire privileges, and cannot signal or inspect trusted supervisors.
Trusted setup/termination capabilities are container-internal only. No
privileged container, host firewall changes, or elevated host setup is approved.

The trusted per-run Engine transport process has no Model-callable Tools. Only
this process uses Engine-owned authentication and provider calls. Credentials
never enter either container, its environment, process arguments, Tool results,
or durable child records. No home, token stores, SSH agents, credential caches,
ambient environment, or Host Server session token is copied to the child.

Provider requests use a supported Engine transport contract bound to the
approved Model, policy, request shape, deadline, and reservations. Child data
cannot select endpoints, headers, credentials, identities, or Tool schemas.
The Host Server authenticates bounded per-run channels outside payload ids;
duplicate, stale, cross-run, malformed, or oversized records are rejected.
DeskPilot does not copy provider HTTP implementations or patch dependencies.

The Engine container must operate with no writable filesystem. Any necessary
runtime storage must fit an explicitly reserved partition of the approved
total, never an unbounded extra temporary mount. Preparation proves the actual
effective mount, network, resource, and native-dispatch policies.

## Context and selected baseline

Only operator-selected Project files and minimum task context enter the child.
Capture current uncommitted bytes without changing the Project, Git index, Git
metadata, or Branch. Do not widen selection to an enclosing repository or
silently omit selected files. Reject oversized or unstable input.

Use validated open file and ancestor handles during capture to prevent path
replacement races. Refuse traversal, aliases, reparse points, junctions,
symlinks, hard links, alternate streams, special files, nested mounts, archive
escapes, shared Git metadata, and credential files. Validate actual bytes and
file identities, not child-supplied metadata or path prefixes alone.

Files, excerpts, Tool results, and child results remain untrusted data with
source and digest provenance. Do not copy parent history, User Profile, Agent
Memory, Attachments, Customization roots, or the parent's system prompt. The
approved Agent body is distinct from retrieved context.

## Storage and limits

The Tool filesystem uses a kernel-enforced byte and inode quota. Seeded input,
writes, directories, temporary data, and output all consume the quota. A
read-only profile has non-writable Project files; a writable profile requires
its own grant. Neither mounts the real Project or another run's storage.

Host records and export staging use capacity reserved before writes, one
installation owner, and bounded writers. Count temporary and retained copies;
do not use directory-size polling as enforcement. Refuse platforms or drivers
that cannot demonstrate the promised bound. Quota exhaustion is a failure,
never silent truncation or partial success.

| Bound | Default | Hard maximum |
| --- | --- | --- |
| Active children / recursive delegation | 1 / 0 | 1 / 0 |
| Total materialized storage per run | 128 MiB | 256 MiB |
| Tool filesystem / host records and export | 96 / 32 MiB | 192 / 64 MiB |
| Selected baseline | 32 MiB, 2,000 files | 64 MiB, 4,000 files |
| Tool filesystem inodes, including directories | 4,096 | 8,192 |
| Proposed changes | 24 MiB, 200 files | 48 MiB, 1,000 files |
| Installation retention / age | 512 MiB / 24 hours | 1 GiB / 7 days |
| Duration / approval wait | 300 / 60 seconds | 600 / 120 seconds |
| Lease expiry / cleanup grace | 15 / 5 seconds | 30 / 10 seconds |
| Combined process memory / CPU / processes | 1 GiB / 1 / 64 | 2 GiB / 2 / 64 |
| Input per request / cumulative input and output | 16,384 / 32,768 tokens | 32,768 / 65,536 tokens |
| Output per request / iterations | 4,096 tokens / 8 | 8,192 tokens / 16 |
| Engine-priced cost / automatic retries | USD 0.25 / 0 | USD 1.00 / 0 |
| Captured Tool output / result | 1 MiB / 256 KiB | 2 MiB / 1 MiB |
| Event size / retained event count | 16 KiB / 300 | 64 KiB / 1,000 |

The memory, CPU, and process partitions across the Engine container, Tool
container, and trusted transport must sum to no more than the run limit. The
deadline includes initialization, capture, approval, provider work, and export.
Cleanup has its separately named grace and never extends execution authority.

Reserve complete-request input, maximum output, and Engine-priced worst-case
cost before every provider dispatch. Include schemas, system text, history,
Tool results, failures, and any resend. Unknown counting or pricing refuses
admission. Unknown Usage retains its reservation; it is not zero. Automatic
retries, including token-refresh and API-shape resends, are disabled.

## Approval and lifecycle

Authority is the intersection of captured parent authority, requested scope,
the profile, and live Permissions. Later changes cannot widen the frozen scope.
The Host Server owns separate child approval records and waits. Fingerprints
bind launch, Conversation, parent Turn, child, attempt, request, policy, and
exact action. There are no inherited, Turn-wide, or Intercom child grants.

An action is prepared without execution. Before committed dispatch, consume a
single approval and recheck live Permissions, generation, policy, deadline,
and limits atomically. A prior denial, expiry, revocation, cancellation, stale
answer, or replay runs nothing. Revocation after dispatch cancels active work;
it cannot undo effects already made in private storage.

Persist ownership before creating resources and immutable container identities
before execution. A failed durable claim prevents launch. Use separate trusted
supervisors whose lease handling does not depend on a busy Engine Runspace or
Tool command. Only authenticated Host Server renewals count. Child output
cannot renew the lease. A Windows Job Object owns the transport process and
descendants and closes on Host Server death.

Stop closes admission and invalidates the generation first, then cancels waits
and provider work, terminates both containers and the transport Job Object, and
verifies absence through an independent control path. Do not accept later child
progress. Final `stopped` requires verified cleanup; `stopping` is not that
claim. Cleanup uncertainty is visible and blocks further child work.

Restart reconciles persisted claims before child admission, marks unfinished
work interrupted, and never replays it. Match installation, launch, child,
attempt, immutable container id, and process start identity, not PID alone.
Remove only positively owned resources. Retain bounded, secret-free evidence.

## Export, presentation, and recovery

Stop Tool descendants before export. Enumerate and read through validated
handles; refuse unsafe links, mounts, paths, aliases, streams, types, and
oversized data. Do not extract child archives on the host. The Host Server
verifies bytes and constructs relative-path operations, sizes, baseline/result
digests, and run provenance. No proposal is applied to the real Project or
reported as its `filesWritten`.

Add explicit authenticated Conversation operations for child start, status,
events, approval, Stop, and proposal retrieval. The window shows one child's
status and exact approval facts. The harness exercises the same operation.
The Host Server is the sole durable Conversation and Usage writer. Child prose
cannot trigger Tools, Memory learning, privileged paths, remote images, active
HTML, or Intercom forwarding. No automatic synthesis is needed in this slice.

Diagnostics separates profile readiness, effective limits, ownership, quota
exhaustion, and cleanup. Prepare, cleanup, and removal are explicit actions;
Self-check never mutates the runtime. Removal disables child admission and
removes only owned child artifacts after verified cleanup. It leaves ordinary
Turns, existing Terminal isolation, Docker, and WSL2 unchanged.

## Threat model and proof gates

Assume hostile Model choices, selected files, Tool commands, and result bytes.
The Tool outbound leg of the lethal trifecta is absent. Selected private data
may reach the explicitly approved Engine provider, which is a trusted
data-processing boundary, not a general network grant. Credential separation
must hold under File reads, Terminal process inspection, output, and errors.
The trusted Host Server, transport implementation, Docker daemon, and shared
WSL kernel remain outside the hostile-child boundary.

Required evidence includes sequential state isolation; positive File/Terminal
work; native disabled-Tool refusal; host/socket/credential/egress attacks;
read-only denial; byte/inode/seed/temporary/export/retention exhaustion; all
approval outcomes and races; Stop during startup, waits, execution, and export;
crash, lease, host death, restart, orphan and failed-cleanup tests; late/malicious
events; honest successful/failed/unknown Usage; unchanged Project/index; and
ordinary single-Agent regression coverage.

Run test-first focused checks, then the full suites and clean actual-runtime
proof. Keep deterministic provider fixtures separate from authenticated live
proof. Complete the requested independent security review and resolve every
Blocker and Major before release. An unavailable or skipped check is open.

## Current evidence

- Admission continuation, 2026-09-06: conditional Engine `RequestLimits` and
  `RequestTokenCounter` reserve a trusted complete-request count, maximum
  output, and Engine-priced cost before dispatch. Failed/unknown Usage retains
  capacity and remains explicitly unknown. Final focused proof: 38 public and
  seven helper cases. Retained Engine commit: `7b8937d` on
  `ai/child-provider-boundary`. No verified Copilot counter is supplied.
- Continuation full gates: Engine **1,810 passed, no failures/skips**, 89.12%
  coverage; unchanged DeskPilot **2,373 passed, five existing browser skips**.
  Both ran 16 tasks without errors/warnings. Independent review approved the
  admission diff with no Blockers/Majors; its Minor test gap is closed. Review
  package: `$env:TEMP/deskpilot-admission-review-20260906-2030`. This does not
  approve the complete child profile or independently re-review the earlier
  storage credential-filter correction. V2 and the startup refusal stay intact.

- Final DeskPilot Sampler build/test gate after the review correction:
  **2,373 passed, zero failures, five existing browser skips**, 16 tasks,
  zero errors/warnings, completed 2026-09-06 11:36:23 UTC. Log under
  `$env:TEMP`: `deskpilot-final-child-full-5e81040ed52343ce93334d6684633884.log`.
  Final source hashes match the retained component proof. Changed PowerShell
  implementation is analyzer-clean; all staged PowerShell parses and both
  staged diffs pass whitespace checks. New Markdown renders and links resolve.

- Final checked-in component proof after the review correction: **87 passed,
  zero failures/skips**, comprising 68 deterministic cases and 19 actual-runtime
  cases, PowerShell 7.6.5, Pester 5.7.1, Docker 29.7.2. Completion:
  2026-09-06 11:32:50 UTC. Source hashes, NUnit results, and explicit open gates
  are retained under `$env:TEMP` in
  `deskpilot-child-proof-f1a1a4399e69454abc7eacf4dbe6af5b`.
  The sibling `.log` retains the full test output. An independent Docker query
  found no containers with the child ownership label afterwards.

- Independent security review returned **request changes**: zero Blockers,
  three Majors, one Minor. Major 1 was an implemented credential-file selection
  defect; common certificate/key/secret paths and structured JSON credential
  fields are now refused, with 15 negative cases red then green and an ordinary
  JSON positive control. All 31 baseline tests pass. The correction is
  author-verified and has not received independent re-review.
- Major 2 (verified Engine request admission) and Major 3 (complete child
  Engine/approval/accounting integration) remain open acceptance gates.
  Minor 1 (retention age and Host Server restart integration) also remains open.
  Do not release or enable child startup with these gates unresolved.
- The review report is retained under `$env:TEMP` in
  `deskpilot-child-review-f1c4705fc78c444b9783c77e21353d21/report.md`, alongside
  its full diffs, authoritative brief, and resolution ledger. Its timestamp
  text is reviewer-authored; the host verification artifacts carry their own
  actual UTC completion times.
- Full pre-review Sampler gates passed: DeskPilot, no failures and five existing
  browser skips; ShellPilot, 1,749 passed with 88.79% coverage. Each ran 16 tasks
  with zero errors/warnings. The later final DeskPilot and component proofs
  above supersede their pre-review counterparts.

- The checked-in component proof passed 71 tests with no failures or skips:
  52 deterministic tests and 19 real-container tests. It includes actual byte
  and inode exhaustion, read-only denial, immutable baseline bytes and handles,
  authenticated IPC, bounded proposal export, busy Stop, lease expiry, owner
  process death, explicit reconciliation, and retention admission.
- Host Server readiness and startup refusal exist; no full child is admitted.
  The credentialless child Engine, approval bridge, complete-run limits, and
  authenticated transport remain unimplemented. This is a partial prerequisite,
  not a complete child Agent or a release-readiness claim.
- The complete-request token bound remains an external contract gap. Engine
  text estimates and after-response spend checks cannot enforce it. Limited
  Engine work now exposes `NoAutomaticRetry` and `RequestTransport`; 185 public
  invocation/transport tests passed. These are local tracked changes only.
- Runtime compilation uses a fresh bounded PowerShell process to avoid loaded
  type collisions. Strict control-directory handles prevent atomic rename, so
  immutable ownership is kept separately from flushed in-place state records;
  an incomplete record refuses admission and requires reconciliation.
- See [the operator guide](../../docs/child-agent-isolation.md) for the exact
  implemented component limits and open gates. Full Sampler checks pass;
  independent review remains request changes for the incomplete prerequisite.

- Adjacent Terminal approval and isolation unit suites: 103 passed, no failures,
  skips, or unrun tests on PowerShell 7.6.5 and Pester 5.7.1, at 08:27 UTC.
- Docker Desktop's local Linux daemon: Engine 29.7.2, WSL2 kernel,
  cgroup v2, CPU/memory/process-limit support, and no containers at inspection.
  Runtime flags are not quota or lease proof.
- Installed ShellPilot: 0.4.0. Staged artifact: 0.4.1, SHA-256
  `1AB55A06244ED302ECAA5B394CF1487DF815EE0237360474178C4BEEAC3DA368`.
- Current `Find-PSResource -Prerelease` result: 0.4.0-preview0010, published
  2026-08-26. The staged artifact is not a clean-install release.
- Real staged Engine loop with inert provider fixtures: a priced zero-dollar
  budget dispatches once and reports USD 0.00208; a one-token context budget
  dispatches despite a 535-token estimate; an API-shape failure dispatches twice
  with `MaxRetryCount = 0` and `MaxToolIterations = 1`. No real provider calls.
- Child policy: first default test red then green; 23 additional policy tests
  red then green, 24 total passing at 09:22 UTC. No child Engine has been launched.

Complete implementation, whole-child actual-runtime proof, authenticated live
proof, obtainable Engine support, and review approval remain open. Parallel scheduling,
combined proposal review/application, and multi-child UI remain in decision
0005 and are not shipped by this work.

## See also

- [Parallel Agents dependencies](0005-parallel-agents.md).
- [Terminal isolation](0001-isolated-tool-execution.md).
- [Terminal approval](0008-per-call-approval.md).
- [Remaining native approval contract](../../specs/120-per-call-approval-engine-contract.md).
