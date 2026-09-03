---
schema-version: 1
status: accepted
owner: software-engineer
last-verified: 2026-09-02
source: repository evidence
---

# 0001 — Optional isolated Tool execution: stop at the architecture decision

## Status

**Blocked at the prerequisite gate, for the second time and for a new reason.**
The architecture decision below is recorded; no runtime code was written.

The 2026-09-02 blockers were resolved by decision 0008. Re-verifying the gate on
2026-09-03 found a different and worse one: the approval boundary 0008 believes
it built is **not enforced by the Engine**. Isolation would fail through exactly
the same hole, and would fail *silently* while the UI claimed containment.

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

Two changes, both inside DeskPilot, neither requiring an Engine release:

1. **Register the owned Tool under a name that is not a built-in** (for example
   `run_terminal_command`). A non-colliding name falls through to the `default`
   clause and actually dispatches. Paired with `-DisableTerminal`, the built-in
   is no longer advertised, so the Model is steered to the owned name by the only
   terminal description it can see.
2. **Close the built-in path rather than relying on the Model's choice.**
   `Set-ShpToolPolicy` is evaluated *before* the dispatch switch (line 11711) and
   a denial returns `{denied}` without executing (line 11730). A policy carrying
   no `Shell` allow makes a stray `run_command` call — from training priors, or
   replayed out of a stored history that predates the rename — fail closed
   instead of running. Price the cost honestly: a policy is deny-by-default for
   `Read` and `Write` too, so DeskPilot must state the file reach it intends in
   the same breath. That is a design change, not a free switch.

Step 1 converts the boundary from fictional to real-but-preference-shaped. Step 2
is what makes it a boundary again. Both belong to decision 0008's slice, not this
one.

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
| **Docker Desktop / WSL2** | Yes, but a large third-party install with licence terms; neither Docker nor WSL present here | ~1 GB plus a WSL2 distro | Bind mounts, `:ro` supported, well understood | `docker kill` terminates the tree | `--network none` plus an explicit allow-list proxy | No ambient host credentials unless mounted | `--rm` plus a reaper | **Preferred, unconfirmed**: the right shape, but the dependency is unapproved and the backend is absent, so nothing can be proven against it today |
| **Hyper-V VM** | Pro/Enterprise, elevation, minutes to start | Very large | Slow (SMB/9p) | Yes | Full | Full | Heavy | **Rejected**: start-up cost defeats a per-command boundary |
| **Job objects** | Native, no dependency | None | **None** — the host file system stays fully visible | Yes | None | None | Trivial | **Rejected as isolation**: it bounds CPU and memory, not reach. Calling it isolation would be the exact mis-marketing the prompt forbids |
| **AppContainer** | Native; profile creation needs no elevation | None | Restriction is by ACL, not namespace: the user profile is denied, but anything granted to `Users`, `Everyone` or `ALL APPLICATION PACKAGES` stays readable | Yes | Real, through absent capabilities enforced by the firewall service | Partial | Trivial | **Rejected for the first slice**: a partial, ACL-shaped boundary that is easy to describe as more than it is, over a large `CreateProcessAsUser` interop surface |
| **Remote SSH host** | Needs a second machine | Operational, not local | rsync/sftp round-trips | Yes | Yes, at the remote's firewall | Yes | Manual | **Deferred**: viable for a team, wrong shape for a single-user desktop app |

**Decision, conditional on both gates opening:** Docker via WSL2, mounting only
the selected Project (`:ro` by default), `--network none`, no `-e` pass-through
except an explicit per-variable allow-list, pinned digest-addressed base image,
`--rm`, and `docker kill` on Stop. Windows Sandbox is the fallback for machines
that already have it and where per-command cancellation can be relaxed.

The dependency itself is **not approved**. DeskPilot installs nothing beyond two
PowerShell modules today; Docker Desktop is a different order of commitment, and
on this machine it would additionally mean installing WSL2 first. That call
belongs to the operator, not to this record.

## Prerequisite list

1. **Fix the dispatch bypass** (the two steps above), so the owned Terminal Tool
   is actually the code path a terminal call reaches.
2. **Prove it end to end, not by parameter inspection.** One live Turn with
   approval on, in which a command the safe-list does not cover produces a
   pending approval and no execution. Until such a test exists, any statement
   that a Tool is gated is an inference.
3. **Approve the dependency.** Docker Desktop plus WSL2, or an explicit decision
   to ship no isolation.
4. A Diagnostics probe for backend presence, version and orphaned containers.
5. A hostile-workload test corpus: a build script that reads `$HOME`, resolves
   cloud metadata, opens a socket, and follows a junction out of the mount.
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
