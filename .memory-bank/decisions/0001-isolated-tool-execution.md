---
schema-version: 1
status: accepted
owner: software-engineer
last-verified: 2026-09-06
source: repository evidence and operator review confirmation
---

# 0001 - Optional isolated Terminal execution

## Status

**Documentation closeout, 2026-09-06.** The operator confirmed the review passed
and requested the final technical-writer stage. The local cycle is closed with
the [operator guide](../../docs/isolated-terminal.md) covering visible changes,
existing-user compatibility, migration, return to Local, and removal. Source,
tests, and build settings remain at `f6af6fd`; this stage did not rerun executable
tests or an independent code review. The recorded implementation evidence below
still applies. Live authenticated acceptance and an obtainable enforcing Engine
remain explicit release gates, not evidence supplied by the review confirmation.

**Final local evidence, 2026-09-05 23:38 UTC.** Full Sampler: 2286 passed,
0 failed, 5 unchanged browser Unicode skips, 16 tasks, zero errors/warnings.
All 29 real-container isolation tests passed without skips. Deterministic HTTP
acceptance through the built Host Server, real Engine dispatch, bridge and Docker
passed exact-command approval, Activity, Usage mapping, pending changes and Undo
preserving the user's prior edit. Desktop/mobile Playwright checks passed.

The live Copilot profile is explicitly **blocked on reauthentication**:
`/api/models` returned `auth_required`. Provider responses in the successful
deterministic profile were scripted, not live. A publicly obtainable enforcing
Engine remains a clean-install release dependency; nothing is published.

The completed code and records are kept on a local topic branch, without a push.

Independent review's one Major is resolved and regression-protected. HTTP
acceptance additionally found and fixed StrictMode optional-state initialization,
an early Settings-open null access, and double-wrapped pending-change arrays.
Isolated dispatch enforcement is checked even with Terminal Permission off.

**Implementation checkpoint, 2026-09-05.** Local/Isolated selection, Docker
execution, real HTTPS allow-lists, approval/Activity policy metadata, resource
bounds, Stop, pending changes, Diagnostics, setup and removal now exist. The
real-container integration suite passes 29 cases with no skips. The initial
full Sampler run passed 2266 tests; final verification remains in progress.

Independent review produced one Major and no Blockers. The Major was a real
protocol bypass: host/port ACLs permitted plain HTTP on 443 and direct HTTPS
proxy requests without CONNECT. Explicit `connections_encrypted` and HTTPS
protocol checks now refuse both; four protocol regression tests pass. A separate
crash test also required active proxy monitoring, which is now implemented.
The operative setup/limitation guide is `docs/isolated-terminal.md`; older gate
and unavailable-backend statements below are preserved as dated history.

**2026-09-05: approval dispatch proved; full-network implementation authorized.**
The earlier approval of Docker Desktop with WSL2 still stands. The operator
rejected the network-off-only proposal, retained working nonempty allow-lists,
and then directed continuation to completion after the revised proxy, protected
network namespace, and temporary in-container CA design was described. This is
authorization to implement that design, not permission to weaken its policy,
change host certificate trust, enable isolation in the operator's Settings, or
push a remote. Runtime and release evidence remain separate gates below.

The Terminal approval suite now executes `Invoke-Shp` against the staged
ShellPilot 0.4.1, with scripted provider responses and inert executors. With
`-DisableTerminal`, the proposed `run_command` is denied and the native executor
is not called; `run_terminal_command` reaches DeskPilot's injected executor.
An enabled-native positive control calls the native executor once. These are
dispatch assertions, not registration or Activity assertions. Pester 5.7.1:
**63 passed, 0 failed, 0 skipped**. Existing tests separately prove that pending
approval runs nothing, approval resumes execution, denial runs nothing, and an
older Engine is rejected.

This satisfies the prerequisite as a mechanism **when approval is active on a
capable Engine**. It does not establish a live Model/operator acceptance run or
availability in a published Engine. The installed Engine is still 0.4.0; the
tested 0.4.1 is in the ignored dependency directory. A clean-install proof with
an obtainable, enforcing Engine remains a release gate.

Docker health was checked again during this assessment: the explicit
`desktop-linux` context reports Docker Desktop 4.89.0, Engine 29.7.2,
`linux/amd64`, and a WSL2 kernel. Runtime availability is not the current blocker.
Earlier dated statements below about an absent runtime are historical.

**Backend approved, installed and demonstrated 2026-09-05.** The operator
approved Docker Desktop plus WSL2 and then asked for the install to be done for
them; the session already held Administrator, so no UAC prompt was involved.
`wsl --install --no-distribution` brought WSL **2.7.13** and flipped
`Microsoft-Windows-Subsystem-Linux` and `VirtualMachinePlatform` from Disabled
to Enabled (Hyper-V was already on). `winget install Docker.DockerDesktop`
installed **4.89.0**. **No reboot was needed** despite DISM asking for one: the
engine answered 47 s after Docker Desktop was started. Backend is WSL2 —
`wsl -l -v` shows the `docker-desktop` distro Running at VERSION 2. Server
engine 29.7.2, `linux/amd64`, context `desktop-linux`.

Prerequisite 3 is therefore closed. Prerequisites 2, 4, 5 and 6 remain open.
The new dispatch tests improve prerequisite 2's evidence but do not replace the
live operator acceptance run. The implementation profile follows the operator's
full-network requirement and continuation instruction, not merely the earlier
dependency installation approval.

## Implementation profile

This keeps the approved Docker Desktop/WSL2 execution boundary and makes its
operating policy explicit. Every guarantee still requires executable proof.

### Ownership and approval

- `Local` remains the default, including for existing Settings and Conversations.
   Its current Engine execution behavior remains unchanged.
- `Isolated` always disables the native Terminal Tool and owns
   `run_terminal_command`. Its approval boundary remains active even if the Local
   `perCallApproval` Setting is off. No setting change, dependency failure, crash,
   or declined command may select `Local` implicitly.
- Terminal Permission off still means no Terminal Tool. When Terminal is on but
   User Tools Permission prevents the owned Tool being offered, refuse the
   Isolated Turn before invoking the Engine. Never restore the native command to
   compensate for a missing owned Tool.
- Freeze the execution policy for each Turn. Bind command approval to its mode,
   Project, mapped working directory, access, limits, and environment selection
   as well as the existing Conversation, Turn, and command identity. A policy
   change applies only to a later Turn and cannot alter a pending approval.
- Show `Local` or `Isolated` beside Terminal Permission, on each Terminal
   approval, and on command Activity. State explicitly that File, Browsing, MCP,
   and Intercom are not isolated by this feature.

### Container and filesystem policy

- Use the local Docker Desktop Linux daemon only. Reject remote contexts and
   ambient endpoint overrides. The Model cannot supply daemon arguments, mounts,
   image references, environment policy, or resource limits.
- Use one disposable container per command, a digest-pinned official PowerShell
   Linux image, a non-root user, a read-only image filesystem, dropped
   capabilities, no new privileges, and the default seccomp policy. Pin and record
   the image digest, source, platform, and PowerShell version during explicit
   setup; never pull or build an image on the Turn path. The earlier Alpine digest
   is evidence for the mount experiment, not a production PowerShell runtime.
- Mount only the selected, validated local Project at `/project`, read-only by
   default. Offer read-write as a separate explicit choice. Do not mount home,
   drive roots, host aliases, control sockets, credential stores, SSH agents,
   host namespaces, or host devices. Refuse unsupported Project paths instead of
   choosing another folder.
- Exclude nested mounts and refuse unsafe reparse-point paths. Keep `/mnt/host`
   and every host-drive alias absent. Validate the working directory against the
   mounted Project and map it to `/project`; do not interpret a prefix match as
   proof of filesystem containment. Prove junction, symlink, case, archive, and
   mount-alias cases against the actual Windows sharing implementation.
- Map resulting paths back to Project-relative Activity and pending changes.
   Keep pre-Turn snapshots, the user's prior changes, and Undo semantics intact.
   A container's own temporary files are not Project changes.

### Environment and network policy

- Build the command environment from fixed runtime essentials and an explicit
   per-variable allow-list, empty by default. Resolve selected values on the
   trusted Host Server side; never inherit the ambient environment wholesale.
   Secret entries expose names and secret markers only, not values in Settings
   responses, approvals, process arguments, Diagnostics, or persisted records.
   Credential redaction and hostile-output tests remain required; an allow-list
   is not permission to display a secret.
- Network is off by default using `--network none`. The operator expressly
  retained usable nonempty outbound allow-lists; an offline-only implementation
  does not satisfy this decision.
- The additional mode permits exact public HTTPS origins on port 443, not
  arbitrary TCP, SSH, UDP, QUIC, IP literals, wildcard subdomains, or automatic
  redirect grants. Names are normalized before policy is frozen for the Turn.
  Clients that ignore the proxy or reject its temporary CA fail visibly; never
  open a direct route or disable certificate verification to compensate.

### Enforced HTTPS allow-lists

Use a disposable Squid TLS-filtering proxy in a protected private network
namespace. Docker Desktop remains the only execution backend. HTTP and TLS
parsing belong to the maintained proxy, not a second parser in DeskPilot.

1. The trusted Host Server resolves only user-approved names with a deadline,
   rejects non-public and mixed public/private answers, and freezes the
   name/address map. No command or proxy DNS egress is permitted during
   execution, including Docker's `127.0.0.11` resolver. An address change needs
   another validated policy, never an unchecked fallback lookup.
2. A trusted container installs namespace-local default-deny packet rules
   before any command starts. Its short-lived setup needs `NET_ADMIN`; the
   command and proxy processes retain no network administration authority.
   Windows and WSL host firewall rules remain untouched.
3. The command joins the protected network namespace, not the host namespace,
   while retaining separate mount, process, and IPC namespaces. Its fixed
   unprivileged UID can reach only the loopback proxy port. A separate proxy
   UID can reach only pinned public destination-address/443 pairs. Deny
   unmatched and ownerless packets, direct DNS, raw sockets, and IPv6 unless an
   equivalent policy has been demonstrated. Verify actual UID separation and
   packet rules before starting the command.
4. Authorize CONNECT authority before upstream contact, require matching TLS
   SNI, inspect decrypted HTTPS, and authorize every HTTP authority and Host
   header. Reject missing, duplicated, conflicting, and malformed authority,
   non-HTTP tunnels, and redirects to unapproved origins. Keep upstream
   certificate validation enabled. CONNECT-only tunneling is insufficient
   because an allowed address can serve an unapproved virtual host.
5. Generate a per-command CA with its private key only in the proxy's bounded
   private temporary storage. Share only the public certificate read-only with
   the command; never install it in Windows, a host browser, the user profile,
   or the Project. Disable proxy caching and content/access logs. The proxy has
   no Project mount, host credentials, or container control socket.
6. Treat command, proxy, and temporary certificate/policy resources as one
   disposable environment. Start only after configuration and boundary probes
   succeed. A proxy failure retains deny rules and stops the command. Stop,
   crash, and startup failure must remove the whole owned environment; a failed
   cleanup remains visible and blocks further Isolated work.
7. Prove a successful allowed-origin fetch as well as unapproved hosts,
   subdomains, redirect escapes, SNI/Host disagreement, missing authority,
   direct sockets with proxy variables cleared, DNS exfiltration and rebinding,
   metadata addresses, and UID/rule tampering. Observe forbidden traffic from
   outside the command container. Removing a critical control must make its
   test fail; an error message alone is not evidence that no request escaped.

An approved origin may receive data deliberately sent to it. This is not an
account, URL-path, HTTP-method, or data-loss-prevention boundary. Certificate
pinning and mutual TLS are unsupported rather than silently bypassed.

Pin an OpenSSL-enabled Squid build with the required directives. The retrieved
documentation says `ssl_bump` is absent from v8 and defaults to an uninspected
TCP tunnel when not configured. `host_verify_strict` alone is insufficient:
missing or valueless Host headers disable its checks. The effective
configuration and those hostile cases require tests.

| Rejected alternative | Reason |
| --- | --- |
| Proxy environment variables alone | A command can ignore them or use raw sockets. |
| Internal bridge plus proxy alone | Connected local addresses and Docker's forwarding DNS resolver still need enforcement. |
| Host-wide firewall changes | They affect unrelated traffic and add an elevated host policy lifecycle. |

### Limits, Stop, and lifecycle

- Proposed defaults: 120-second command deadline, one CPU, 1 GiB memory with no
   additional swap, 64 processes, 1 MiB combined captured output, and 128 MiB
   bounded temporary storage. Validate support and read back effective limits;
   do not treat accepted command-line flags as proof of enforcement.
- CPU quota throttles rather than failing a command immediately. Test that
   throttling actually occurs and that the wall-clock limit ends runaway work.
   Memory, process, output, temporary-storage, and timeout failures must be
   visible, bounded results rather than silent truncation or apparent success.
- **No total disk quota is promised for a read-write Windows Project bind.**
   The temporary-storage cap is not a cap on Project writes. Surface this
   limitation before selecting read-write, and do not report a Project disk bound
   as passed. A hard total Project-write quota would require another storage
   design and new copy-back/Undo proofs.
- Track ownership before starting the command. Stop must terminate the whole
   container, not just its CLI client, then remove it and verify absence. Cover
   Stop during create/start, detached descendants, timeout, crash, and cleanup
   failure. Cleanup failure remains visible and blocks further Isolated work
   until the owned resources can be inspected and removed.
- Diagnose runtime presence, version, image provenance, required capabilities,
   and owned orphan resources before a Turn starts. Diagnostics cleanup targets
   only positively identified DeskPilot resources; never use a global prune.
- Disposable means no persistent container or unnamed volume. Explicit Project
   writes persist only because the operator selected read-write. Returning to
   `Local` does not undo those writes; Keep and Undo retain their existing roles.

### Threat model and release gate

Assume an injected Agent and a hostile Project build script. Project content and
Tool output are untrusted. Narrow mounts and an empty default environment remove
ambient host credentials from Terminal reach; network-off breaks the Terminal
process's outbound leg, while an explicit allow-list restricts it to approved
HTTPS origins. Secrets already in the selected Project remain readable inside
that Project and can be sent to an approved origin. Other enabled Tools retain
their existing
authority, so this is not isolation of an entire Agent or protection against a
compromised Host Server, Docker daemon, or shared WSL kernel.

Before release, require real-container hostile-workload tests, pending approval
and denial with no side effects, Stop and cleanup proofs, accurate Activity and
Usage, pending changes and Undo, an operator acceptance run, clean-install Engine
availability, the full Sampler gate, and an independent security review. A
skipped suite is not evidence. Architecture, API, UI, security, setup, roadmap,
Diagnostics, migration, and cleanup documentation ship with the implementation,
not as a claim that this proposal already works.

## Performance and rollback comparison

This supplements the mount, network, credential, cancellation, and Windows
comparison below. These are design tradeoffs, not measured performance results.

| Candidate | Performance and remaining proof | Rollback and dependency removal |
| --- | --- | --- |
| Docker Desktop / WSL2 | Reuse the daemon, never a command or proxy container. Measure pair startup, TLS filtering, and Windows bind I/O; availability checks are not benchmarks. | Explicitly select Local, remove the owned pair and temporary certificate/policy resources, then remove only DeskPilot-owned runtime artifacts. Docker and WSL removal is a separate operator action because other workloads may use them. |
| Windows Sandbox | Startup and automated command cancellation need proof; no command-level performance result is recorded. | Close the disposable environment, select Local, and leave shared Windows features enabled unless the operator separately removes them. |
| Hyper-V VM | Boot, image distribution, and file transfer add lifecycle work; no measured startup budget is recorded. | Remove only owned VM and disk artifacts after verifying shutdown; keep shared virtualization features. |
| Job objects | Low integration overhead does not establish filesystem, credential, or network isolation. | Remove the process wrapper; not an acceptable Isolated implementation. |
| AppContainer | Native execution avoids a container runtime but requires an independently tested ACL and process-launch boundary. | Remove only owned profiles and grants; not selected for this slice. |
| Remote SSH host | Transfer and connection costs depend on another machine and its policy. Shared or cloud execution is out of scope. | Terminate owned remote work and remove only its staging data; remote credentials and host lifecycle need their own design. |

## Source checks for the current proposal

Docker documentation was fetched on 2026-09-05. These sources establish the
mechanisms; workload tests must establish DeskPilot's use of them.

| Claim | Verified source section | Consequence |
| --- | --- | --- |
| Network `none` creates only loopback. | [None network driver](https://docs.docker.com/engine/network/drivers/none/) | A positive outbound allow-list is additional work, not a flag on this network. |
| Bind mounts are writable by default, and nested mounts are included by default. | [Bind mounts: constraints and recursive mounts](https://docs.docker.com/engine/storage/bind-mounts/) | Specify read-only and nested-mount policy; do not infer them. |
| CPU quotas throttle, and equal memory/swap limits prevent extra swap. | [Resource constraints: CPU and memory-swap](https://docs.docker.com/engine/containers/resource_constraints/) | Validate effective limits and test their different failure behavior. |
| `docker kill` sends SIGKILL to the main container process by default. | [Container kill: description](https://docs.docker.com/reference/cli/docker/container/kill/) | Descendant termination and cleanup are still application acceptance tests. |
| WSL distributions share a kernel, and Windows can access WSL files. | [WSL2 security in Docker Desktop](https://docs.docker.com/desktop/features/wsl/#wsl-2-security-in-docker-desktop) | Do not describe this as a separate VM-grade or hostile-host boundary. |
| Containers can share a network namespace; Docker's embedded DNS forwards external queries. | [Container networks and DNS services](https://docs.docker.com/engine/network/) | Shared namespace rules must also deny DNS escape. |
| Packet owner matching applies to local OUTPUT/POSTROUTING and socket UID ownership. | [iptables extensions: owner](https://man7.org/linux/man-pages/man8/iptables-extensions.8.html) | Default-deny unmatched packets and prove UID separation. |
| Squid can inspect TLS, but defaults to a TCP tunnel. | [ssl_bump](https://www.squid-cache.org/Doc/config/ssl_bump/) | Pin an appropriate build and require explicit inspection. |
| Missing Host headers disable strict Host checks. | [host_verify_strict](https://www.squid-cache.org/Doc/config/host_verify_strict/) | Explicitly refuse missing/conflicting authority. |
| Unmatched access rules can invert the last rule. | [http_access](https://www.squid-cache.org/Doc/config/http_access/) | Include and test an explicit final deny. |

## What the backend was measured to guarantee

Run against `alpine@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce`,
pinned by digest as the decision requires. Four of the chosen properties hold on
this machine:

| Property | Evidence |
| --- | --- |
| Network default-deny | `--network none`: outbound fetch fails, **0** non-loopback interfaces |
| Project mounted read-only | `-v <project>:/project:ro`: `README.md` readable, `touch` refused |
| No host reach | none of `/mnt/c`, `/mnt/d`, `/c`, `/d`, `/host_mnt`, `/Users`, `/run/desktop/mnt/host` exists |
| No ambient environment | a `ghp_`-shaped marker exported in the host shell is absent from `env` |
| Cleanup | `--rm` left **0** containers |

### The junction did not escape, and the reason is not a refusal

The sharpest measurement, and the one that must not be written down as a
guarantee. A fixture was built on the same drive: a mounted folder containing an
NTFS **junction** pointing at a sibling secret folder outside it. Reading through
the junction failed, and so did `..` traversal — but the mechanism is not
containment.

`/proc/mounts` shows the bind as 9p with **`aname=drvfs;path=D:\`**: the share is
rooted at the **whole D: drive**, not at the Project. Narrow reach is enforced by
the *mount point*, not by the share. And the junction is translated into a
symlink — `esc -> /mnt/host/d/dp-escape-secret`, per the mount's own
`symlinkroot=/mnt/host/` option. The read fails only because **`/mnt/host` does
not exist inside the container**.

So the escape is blocked by what is *absent* from the namespace, and it inverts
the moment anything is present there. Mounting the host at `/mnt/host` — a
plausible convenience — would turn every junction inside a Project into a live
read of the host. That is an **invariant to test on every run**, not a property
to assume: nothing may be mounted at `/mnt/host`, and a test must fail if
something is. It seeds prerequisite 5.

This is the same shape as the five Blockers decision 0003 records: a correct fact
about one component written down as a guarantee about another.

---

**Dependency approved 2026-09-05; still blocked, now on the install itself.**
The operator approved Docker Desktop plus WSL2 when the trade was put to them
with today's measurements. That closes prerequisite 3 as a *decision* and
reopens it as a *task*: nothing is installed, and both installs need elevation,
so no isolation claim can be proven yet. No runtime code has been written, and
none should be until a command has been observed running inside a container.

**Machine state re-measured 2026-09-05, unchanged from 2026-09-03.** `docker`,
`podman` and `nerdctl` absent; `wsl.exe` present as the inbox stub but
`wsl --list` exits 1 with *"The Windows Subsystem for Linux is not installed"*;
`Containers-DisposableClientVM` **Disabled** and `WindowsSandbox.exe` absent.
Windows 11 Enterprise. Re-measured rather than read back, because this record's
own history is three corrected inherited claims in two days.

**Approval reachability, recorded and deliberately not fixed.** The prompt's
gate asks that per-call approval be implemented *and enforced*. The mechanism
enforces: `Initialize-DpTerminalTool` probes `Invoke-Shp` for the
`offeredBuiltInTool` marker and throws without it. Measured today, that marker
is in **0.4.1 (3 hits), staged only in this repository's `output/`**, and
**absent from 0.4.0 (0 hits)**, which is both the installed build and the newest
published one. `RequiredModules.psd1` pins `'latest'` and `perCallApproval`
ships off, so on every machine but this one the boundary isolation is meant to
sit on top of cannot be switched on at all — it fails closed, which is the safe
direction, but it is not an active boundary anywhere. Put to the operator on
2026-09-05 as a competing priority; they chose to record it and move on.

The 2026-09-02 and 2026-09-03 history below is kept in full because it is the
evidence for prerequisites 2 and 6 and for two anti-patterns.

---

**Blocked at the prerequisite gate, for the second time and for a new reason.**
The architecture decision below is recorded; no runtime code was written.

The 2026-09-02 blockers were resolved by decision 0008. Re-verifying the gate on
2026-09-03 found a different and worse one: the approval boundary 0008 believed
it had built was **not enforced by the Engine**. Isolation would have failed
through exactly the same hole, and would have failed *silently* while the UI
claimed containment.

> **Gate half-open, 2026-09-03.** The boundary defect below was fixed the same
> day: ShellPilot refuses to dispatch a built-in a call did not offer and refuses
> to register a Tool under a built-in's name, and DeskPilot's Tool is now
> `run_terminal_command` behind a capability probe. Per-call approval is now
> implemented **and** enforced, so this gate is met. Isolation remains blocked on
> its *own* prerequisites: the Docker/WSL2 dependency is unapproved, and the
> development machine has no container runtime, no WSL and Windows Sandbox
> disabled, so no isolation claim can be proven against a backend today. The
> finding below is kept in full because it is the evidence for prerequisite 6 and
> for two anti-patterns.

## The gate

`.github/prompts/implement-isolated-tool-execution.prompt.md` requires:

> Confirm per-call approval is implemented and enforced before proceeding. If it
> is absent, stop after producing the architecture decision and prerequisite
> list; do not ship isolated execution as a substitute for action-level approval.

Per-call approval is **implemented** (decision 0008, commit `3c3048e`). It is
**not enforced**. Implemented and enforced are not the same claim, and only the
second one opens this gate.

## Finding: a registered `run_command` User Tool is never dispatched

Measured against the installed Engine, ShellPilot 0.4.0 (`ShellPilot.psm1`), not
inferred from DeskPilot's own parameters.

**1. The dispatch switch has a literal `run_command` clause, and User Tools live
only in its `default`.** Extracted from the module AST rather than read by eye:

```text
SWITCH lines 11733-11842  cond=$tc.Name
clauses: 'fetch_url' | 'read_file' | 'list_directory' | 'write_file' |
         'create_directory' | 'run_command' | 'ask_user' | 'load_skill' |
         'load_instruction' | 'manage_todo_list'
enclosing ifs: IF -not $access.Allowed <- IF $turn.ToolCalls.Count -gt 0
```

`$userToolCommands` is consulted in the `default` clause (line 11828). A
PowerShell `switch` runs `default` only when no other clause matched, so a User
Tool named `run_command` is unreachable: the built-in clause matches first and
calls `Invoke-RunCommandTool` at line 11762.

**2. `-DisableTerminal` does not gate that clause.** `$terminalEnabled` occurs at
lines 10875, 10954, 11083, 11185 and 11997 — the offered tool definition, the
system-prompt nudge, and the result summary. It does not occur anywhere in the
dispatch region (11690-11845), and the AST shows no enclosing condition beyond
the access-policy check.

**3. Nothing prevents the collision.** `Register-ShpTool` does not compare the
requested name against `$script:ShpBuiltInToolName` (line 345, which lists
`run_command`); only the MCP attach path does, at line 13113. Registration
succeeds, and the schema is added to the offered tool list at line 11035 with no
de-duplication against the built-ins.

**Consequence.** With approval on, DeskPilot advertises its own `run_command`
description, the Model calls `run_command` as invited, and the Engine runs the
command on the host through its own built-in. The approval bridge is never
reached. No card is shown, nothing is denied, and the command runs. The Activity
row still appears, because it is built from the progress record — precisely the
after-the-fact signal this repository already records as *not* a boundary.

**Why the existing tests missed it.** `tests/Unit/TerminalApproval.Tests.ps1`
asserts `passes -DisableTerminal so the Engine keeps no run_command of its own`.
That test proves DeskPilot builds a parameter, then infers an Engine property
from it. The Engine was never asked.

**Blast radius today is nil, and that is luck rather than design.**
`perCallApproval` ships off, so nobody is currently relying on a gate that does
not hold. The defect is the false promise waiting behind the Setting.

## Why this blocks isolation specifically

Isolation was going to replace the executor scriptblock
(`$global:DeskPilotTerminalExecutor`, built inside the Engine Runspace by
`Initialize-DpTerminalTool`). That seam is real and DeskPilot fully owns its
body — but it sits *inside* `Invoke-DpTerminalApprovalTool`, which the finding
above shows is never invoked. An isolated executor would therefore be installed,
reported in the UI, and bypassed: every command would run unconfined on the host
while an `Isolated` badge sat beside it.

That is the failure mode the prompt names twice — "never market process-level
wrapping as isolation" and "do not call the mode isolated" — reached by a
different route. Shipping it would be worse than shipping nothing.

## The fix this now depends on

**Shipped 2026-09-03**, and not where this record expected. The root cause was
upstream, so it was fixed upstream rather than worked around:

1. **ShellPilot refuses to dispatch a built-in the call did not offer.** The
   offered set is derived from the assembled tool list, and the refusal reuses
   the existing tool-policy denial path, so the `tool.call` event, the
   `ToolCallsDenied` member and the model's result shape are unchanged. A
   `run_command` named from training priors or a replayed history now fails
   closed. This makes `-DisableTerminal` mean what every caller already believed
   it meant, for every consumer of the module, not just DeskPilot.
2. **`Register-ShpTool` refuses a built-in name.** MCP attachment had always been
   refused a colliding name for exactly this reason; a local registration was
   not, which is the more dangerous of the two because the caller believes it
   replaced the built-in.
3. **DeskPilot's Tool is `run_terminal_command`**, and registration probes the
   Engine for the dispatch refusal, failing loudly without it. A gate that cannot
   be honoured must not report as active.

`Set-ShpToolPolicy` was the planned second step and proved unnecessary for
closing the hole. It remains attractive on its own merits as a "Project scope"
Setting — a real, zero-dependency reach restriction — but it is a separate slice
with a real cost to price: a policy is deny-by-default for `Read` and `Write`
too, so DeskPilot would have to state the file reach it intends.

## Backend comparison

Assessed against the prompt's criteria for a Windows-first, CurrentUser,
no-elevation product. Availability re-measured on the development machine on
2026-09-03: Windows 11 Enterprise, **no `docker`, no `podman`, WSL not installed
(`wsl --list` reports the Subsystem absent), and `Containers-DisposableClientVM`
Disabled.** Every candidate below is therefore currently unavailable without an
elevated install.

| Backend | Windows | Dependency burden | Mounts | Cancellation | Network control | Credential isolation | Cleanup | Verdict |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| **Windows Sandbox** | Pro/Enterprise only, needs Hyper-V + an admin feature install (measured Disabled here) | Ships with Windows | `<MappedFolder>` per-folder, read-only supported | No process API; the whole sandbox is the unit | `<Networking>Disable</Networking>` only — all or nothing | Clean: fresh profile, no ambient tokens | Disposable by construction | **Rejected**: Home editions excluded, elevation to enable, and no per-command cancellation |
| **Docker Desktop / WSL2** | Yes, but a large third-party install with licence terms; neither Docker nor WSL present here | ~1 GB plus a WSL2 distro | Bind mounts, `:ro` supported, well understood | `docker kill` terminates the tree | `--network none` plus an explicit allow-list proxy | No ambient host credentials unless mounted | `--rm` plus a reaper | **Chosen, unproven**: approved 2026-09-05, but still absent from this machine, so nothing has been demonstrated against it |
| **Hyper-V VM** | Pro/Enterprise, elevation, minutes to start | Very large | Slow (SMB/9p) | Yes | Full | Full | Heavy | **Rejected**: start-up cost defeats a per-command boundary |
| **Job objects** | Native, no dependency | None | **None** — the host file system stays fully visible | Yes | None | None | Trivial | **Rejected as isolation**: it bounds CPU and memory, not reach. Calling it isolation would be the exact mis-marketing the prompt forbids |
| **AppContainer** | Native; profile creation needs no elevation | None | Restriction is by ACL, not namespace: the user profile is denied, but anything granted to `Users`, `Everyone` or `ALL APPLICATION PACKAGES` stays readable | Yes | Real, through absent capabilities enforced by the firewall service | Partial | Trivial | **Rejected for the first slice**: a partial, ACL-shaped boundary that is easy to describe as more than it is, over a large `CreateProcessAsUser` interop surface |
| **Remote SSH host** | Needs a second machine | Operational, not local | rsync/sftp round-trips | Yes | Yes, at the remote's firewall | Yes | Manual | **Deferred**: viable for a team, wrong shape for a single-user desktop app |

**Decision, conditional on the backend being installed and demonstrated:** Docker
via WSL2, mounting only the selected Project (`:ro` by default), `--network
none`, no `-e` pass-through except an explicit per-variable allow-list, pinned
digest-addressed base image, `--rm`, and `docker kill` on Stop. Windows Sandbox
is the fallback for machines that already have it and where per-command
cancellation can be relaxed.

**The dependency was approved by the operator on 2026-09-05.** The trade was put
to them with the day's measurements: DeskPilot installs nothing beyond two
PowerShell modules today, Docker Desktop is a ~1 GB third-party install carrying
licence terms, and on this machine it means installing WSL2 first — both
elevated. They took it over the Windows Sandbox fallback, over shipping no
isolation, and over the zero-dependency `Set-ShpToolPolicy` alternative.

Approval is not installation. Until `docker version` answers from this machine,
every isolation test would skip, and the prompt is explicit that a skipped
isolation suite is not release evidence.

## Prerequisite list

1. ~~**Fix the dispatch bypass**, so the owned Terminal Tool is actually the code
   path a terminal call reaches.~~ **Done 2026-09-03**, upstream in ShellPilot
   plus the rename in DeskPilot.
2. **Prove approval end to end with a live Turn.** Registration and dispatch are
   now proved against a real Engine in `tests/Unit/TerminalApproval.Tests.ps1`,
   including that the capability probe rejects an Engine without the fix. What is
   still unproven is a real Model choosing the Tool and a real operator answering
   the card.
3. ~~**Install the approved backend.**~~ **Done 2026-09-05.** WSL 2.7.13 plus
   Docker Desktop 4.89.0, WSL2 backend, engine 29.7.2, no reboot required. The
   four chosen properties are demonstrated above.
4. A Diagnostics probe for backend presence, version and orphaned containers.
5. A hostile-workload test corpus: a build script that reads `$HOME`, resolves
   cloud metadata, opens a socket, and follows a junction out of the mount.
   **Seeded 2026-09-05** by the junction fixture above, which also produced the
   `/mnt/host` invariant the corpus has to assert.
6. **Isolated mode must own the Tool independently of `perCallApproval`.** Today
   `Set-DpTerminalTool` registers the owned Tool only when `Test-DpApprovalActive`
   is true, so with approval off there is no seam at all. Isolation cannot
   inherit a gate that a separate Setting can switch off.

## Historical stop state

At the earlier prerequisite stop there was no `Local`/`Isolated` mode toggle,
no container code, no Settings key, and no UI
affordance. A visible mode switch that does not actually contain anything is
worse than its absence: it converts an honest limitation into a false promise.
The bypass found today is the same mistake one layer down, already shipped —
which is the strongest available argument against stacking a second one on top
of it.
