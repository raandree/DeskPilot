---
schema-version: 1
status: accepted
owner: software-engineer
last-verified: 2026-09-05
source: repository evidence
---

# 0001 — Optional isolated Tool execution: stop at the architecture decision

## Status

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

Prerequisite 3 is therefore closed. Prerequisites 2, 4, 5 and 6 are open, and no
runtime code has been written.

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

## What was deliberately not done

No `Local`/`Isolated` mode toggle, no container code, no Settings key, and no UI
affordance. A visible mode switch that does not actually contain anything is
worse than its absence: it converts an honest limitation into a false promise.
The bypass found today is the same mistake one layer down, already shipped —
which is the strongest available argument against stacking a second one on top
of it.
