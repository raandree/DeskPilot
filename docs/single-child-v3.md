# Single-child V3

This guide covers the opt-in private child for operators and contributors.
V3 uses explicitly estimated provider budgets. Its File and Terminal Tools are
confined, its proposals stay private, and ordinary Turns are unchanged.
Readiness requires proof of the exact prepared implementation, not just a
successful image build. A local Engine build is not a published dependency.

## Scope and trust boundary

One child owns execution at a time. The Host Server reserves the active Turn
before selected-file capture; the parent Engine Runspace remains idle. Another
Turn, schedule, or Engine helper cannot overlap that authority.

The child has a fresh Engine process in a separate, non-root Linux container.
It has no network, host mounts, writable filesystem, or credentials. Empty
PowerShell home/XDG directories are immutable image content. Only fixed owned
File and Terminal adapters are registered. Native File/Terminal dispatch,
Browsing, MCP, Vision, Ask-User, arbitrary User Tools, customization discovery,
and recursive delegation are unavailable.

The separate Tool container has no network or host mounts. Its private Project,
temporary files, and home share a kernel-enforced byte/inode quota. Tool code
runs unprivileged with no capabilities. The container-internal supervisor owns
only the capabilities needed to initialize storage and stop Tool descendants.
Read-only Project access is enforced by ownership and file modes. Linux
`openat2` confines File operations; Terminal cannot reach the real Project.

Only the trusted Windows provider process resolves Engine credentials. It has
no registered Tools. A suspended launch is assigned to its kill-on-close Job
Object, and its process/start identity is recorded before resume. Docker
control clients share that job. Authenticated per-run IPC binds direction and
sequence, rejects duplicate properties, and bounds frames and complete messages.

The Host Server, trusted Engine transport implementation, Docker daemon, and
shared WSL kernel are trusted. This is not protection against their compromise
or against another program already running with the operator's host authority.
Credential filename/content checks are conservative selection safeguards, not
proof that arbitrary selected content contains no secrets.

## Provider budgets

The selected Model must be `claude-haiku-4.5`. The Engine generates using Chat
and counts through Copilot's hosted Messages counting operation. Both receive
the task, approved Agent text, Tool schemas, conversation messages, and Tool
results. The run's consent explicitly covers both disclosures. No other
provider or general outbound channel is authorized.

| Budget | Default | Maximum setting |
| --- | ---: | ---: |
| Estimated input per request | 16,384 tokens | 32,768 tokens |
| Non-refundable input/output reservations | 32,768 tokens | 65,536 tokens |
| Requested output per request | 4,096 tokens | 8,192 tokens |
| Engine-priced estimated cost | USD 0.25 | USD 1.00 |

These are not guaranteed token or invoice caps. The hosted count is an
estimate, not an exact count or verified upper bound. Actual charges may exceed
the estimates; no maximum financial overrun is established. A request already
sent cannot be unbilled by Stop.

Each complete supported request is converted without dropping input. Named
Chat Tool results must match their preceding named call; Messages preserves
that name through `tool_use_id`. Unsupported shapes refuse counting and
generation. The trusted provider freezes routes, Model, schemas, price table,
deadline, and limits. It reserves counted input plus maximum output before
generation and obtains fresh Host Server admission after counting. Failed
requests retain their reservations. No count correction or heuristic fallback
is used.

Reported Usage and reservations are separate. Charges reconcile upward, never
refund within the run. Underestimates within all adjusted budgets may continue.
An overrun stops before another Tool/provider dispatch. Missing Usage retains
the reservation, reports unknown totals and known partial Usage, and stops
continuation. Missing pricing ends before authentication with
`pricing-unavailable`. Malformed Usage, changed identity, output-cap violations,
and invalid counts fail closed.

## Hard local limits

| Control | Default | Maximum setting |
| --- | ---: | ---: |
| Generation attempts / counting attempts | 8 / 8 | 16 / 16 |
| Initialization HTTP attempts | 2 | 2 |
| Total HTTP attempts | 18 | 34 |
| Serialized request | 256 KiB | 1 MiB |
| Count response | 16 KiB | 64 KiB |
| Generation response / captured Tool output | 1 MiB | 2 MiB |
| Complete duration / approval wait | 300 / 60 seconds | 600 / 120 seconds |
| Lease / cleanup grace | 15 / 5 seconds | 30 / 10 seconds |
| Combined memory / CPU / process limit | 1 GiB / 1 / 64 | 2 GiB / 2 / 64 |
| Total storage / Tool storage | 128 / 96 MiB | 256 / 192 MiB |
| Tool filesystem inodes | 4,096 | 8,192 |
| Selected baseline | 32 MiB, 2,000 files | 64 MiB, 4,000 files |
| Proposed changes | 24 MiB, 200 files | 48 MiB, 1,000 files |
| Result / event / retained event count | 256 KiB / 16 KiB / 300 | 1 MiB / 64 KiB / 1,000 |
| Installation retention / age | 512 MiB / 24 hours | 1 GiB / 7 days |

There are no automatic retries, redirects, API-shape resends, refresh attempts,
or automatic reruns. Count failure authorizes no generation. Model/endpoint
discovery inside the run is part of its two initialization attempts.

Resource partitions sum to the complete limit: the Tool container receives
half the memory/CPU and 40 tasks; the Engine container receives one quarter and
16 tasks; the trusted Windows job receives one quarter and 8 processes.
The process limits count operating-system tasks according to each platform.
The Tool `tmpfs` also consumes its container memory allocation.

Host storage reserves bounded request/response copies and result/Activity
records before accepting proposals. Encoded proposals must fit the remaining
host partition as well as the byte/file ceilings; a configured ceiling is not
a guarantee that every combination fits. Incompatible buffer settings are
refused before launch. Overflow fails rather than silently truncating success.
The Engine container adds no writable mount.

## Approvals, Stop, and recovery

Every private File write and Terminal command needs its own window approval.
The approval binds the launch, Conversation, parent Turn, child, attempt,
generation, request, policy digest, and exact action. File-write facts show the
relative path, byte count, and content digest. Terminal facts show the exact
command. The decision is consumed once immediately before committed dispatch.
There are no inherited grants, Turn-wide grants, or Intercom child approvals.

Stop closes admission first. Live Permission or private-write revocation closes
it too; later Settings cannot widen captured scope. A blocked IPC send or busy
Tool does not prevent cancellation. Each process handles its lease independently
of its Engine Runspace. An authenticated ready acknowledgment distinguishes a
started process from a merely created Docker container.

Both containers and the trusted job must be removed or terminated before a
terminal state claims cleanup success. All cleanup calls share one grace
period. Uncertain cleanup remains `cleanup-failed` and blocks more child work.
Host Server death closes the Windows job; both container leases terminate.
Restart reconciles only positively owned identities, marks unfinished records
`interrupted`, retains Usage reservations, and never replays work. A live exact
provider identity is refused rather than killed from an untrusted PID alone.

Proposals are bounded relative-path data with baseline/result digests. Export
stops Tool descendants, validates archive paths/types, and never extracts child
archives on the host. Proposals never change the real Project, Git index,
pending changes, or Undo. Child results and proposals render as plain text;
they cannot load URLs, execute HTML, teach Memory, or enter parent history.

## Setup and use

Prerequisites are Windows, PowerShell 7.4+, Docker Desktop's local Linux/WSL2
backend with cgroup v2, and an explicitly selected built Engine supporting the
child transport contract. Preparation never installs or switches the Engine.

1. Open a Conversation with the intended Project and explicitly select
   `claude-haiku-4.5`.
2. Open **Private child** and select **V3: estimated budgets**. Changing profiles
   disables child execution; it does not migrate V2 silently.
3. Use **Prepare runtime**, then **Check runtime**. Preparation freezes Engine,
   adapter, and runtime bytes into separate immutable images.
4. Require a Host-owned `child-runtime/profile-proof.json` for those exact
   bytes. It records acceptance, complete Engine/Host gates, actual-runtime and
   authenticated live proof, and independent review with no Blocker/Major
   findings. A source/image/policy mismatch invalidates it. A successful build
   alone must never be promoted to a proof record.
5. After readiness passes, separately enable V3, enter the task and one selected
   Project-relative file per line, and choose read-only or private proposals.
   Give fresh counting/generation estimate consent for each run.
6. Review each exact write/Terminal approval. Inspect Activity, reported Usage,
   reservations, and private proposals in the child panel. Starting a new run
   requires new consent; ordinary edit/regenerate cannot rerun a child task.

The Host Server refreshes backend health at admission. Re-preparing an assembly
after runtime types are loaded requires a Host Server restart so the loaded
bytes match proof. Explicit cleanup and startup reconciliation enforce retention
age. No global Docker prune or shared Docker/WSL removal occurs.

Rollback means Stop, verified cleanup, and disabling the child profile. V2
retains its strict verified-counter gate and is still unavailable without that
contract. There is no Local/native-Tool fallback. Ordinary Turns and existing
Terminal-only modes remain unchanged.

**Remove runtime** disables the child profile first, reconciles owned runs,
then removes only verified child image tags and their preparation files.
Private retained proposals are discarded only after confirmed cleanup. Shared
Docker, WSL2, and Terminal-only runtime data remain installed.

## Host Server operations

All routes retain loopback/origin checks and the per-launch token requirement.

| Method | Path | Behavior |
| --- | --- | --- |
| GET | `/api/diagnostics/child` | Read-only effective policy and source-bound readiness. |
| POST | `/api/diagnostics/child/prepare` | Explicit off-loop immutable image preparation. |
| POST | `/api/diagnostics/child/check` | Explicit read-only backend health refresh. |
| POST | `/api/diagnostics/child/cleanup` | Reconcile owned work and expire retained records. |
| POST | `/api/diagnostics/child/remove` | Disable and remove verified child preparation and private records. |
| POST | `/api/conversations/{id}/child-runs` | Explicit consent and selected-context admission. |
| GET | `/api/conversations/{id}/child-runs/{childId}` | Bounded status, Usage, Activity, and pending approval. |
| GET | `/api/conversations/{id}/child-runs/{childId}/events` | Bounded ordered Activity. |
| GET | `/api/conversations/{id}/child-runs/{childId}/proposal` | Cleaned-up private proposal data. |
| POST | `/api/conversations/{id}/child-runs/{childId}/approval` | One exact approval or denial. |
| POST | `/api/conversations/{id}/child-runs/{childId}/stop` | Close admission and begin cleanup. |

Start requires `consent`, `prompt`, `selectedPaths`, `profile`, `budgetMode`, and
`projectAccess`; unknown scope fields are refused. Approval requires
`approvalId`, `fingerprint`, and `decision` (`approve` or `deny`). Child ids are
Host-generated, and records are confined to their owning Conversation.

## Verification and distribution

Unit tests cover explicit estimated mode, strict-mode compatibility, counting
shape, scalar identities, malformed Usage, non-refundable reservations, approval
replay/revocation, readiness invalidation, and retained records. Actual-runtime
tests cover File/Terminal isolation, quotas, private proposals, Stop at startup,
approval and busy execution, independent leases, whole-host death/recovery,
shared cleanup grace, and authenticated loopback HTTP with an idle parent and
unchanged Project/Git index. Browser checks exercise desktop/mobile consent and
prove hostile HTML remains inert.

The operator-invoked [live proof](../tests/live/child-profile.ps1) uses the same
validated controller and a temporary File-only Project. It does not publish
readiness or enable normal startup. Its default cleanup removes the prepared
image tags. Explicit `-RetainRuntime` keeps those exact images for subsequent
operator proof binding; child containers and provider processes must still be
removed. Retention alone is not evidence that a run passed.

A built Host Server and dot-sourced development functions have distinct proof
fingerprints. Verify the built functions and bundled assets against the reviewed
source, then exercise the built controller and evaluate its own fingerprint.
Never reuse a source-mode proof record for a different launch surface.

Final validation and independent review must match the shipped source and
prepared artifacts. Clean-install Engine availability and remote publication
remain separate release gates; this repository does not silently patch an
ignored dependency or claim that a local Engine build is published.

## See also

- [Accepted V3 amendment](../.memory-bank/decisions/0010-child-budget-estimates.md).
- [Original strict V2 contract](../.memory-bank/decisions/0009-single-child-isolation.md).
- [Historical counting evidence](child-agent-isolation.md#live-counting-investigation).
- [Terminal-only isolation](isolated-terminal.md).
