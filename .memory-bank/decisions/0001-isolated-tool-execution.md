---
schema-version: 1
status: accepted
owner: software-engineer
last-verified: 2026-09-02
source: repository evidence
---

# 0001 — Optional isolated Tool execution: stop at the architecture decision

## Status

**Blocked at the prerequisite gate.** The architecture decision below is
recorded; no runtime code was written.

## The gate

`.github/prompts/implement-isolated-tool-execution.prompt.md` requires:

> Confirm per-call approval is implemented and enforced before proceeding. If it
> is absent, stop after producing the architecture decision and prerequisite
> list; do not ship isolated execution as a substitute for action-level approval.

Per-call approval is **not implemented**. `specs/120-per-call-approval-engine-contract.md`
records why: ShellPilot 0.4.0 has `ShouldProcess` gates but no correlated Host
callback, no trustworthy MCP annotation provenance, no safe summary contract and
no action fingerprint, so DeskPilot cannot block a Tool call before it runs.
The gate is therefore unmet and this work stops here.

## Second, independent blocker found while assessing the gate

The prompt also requires verifying, from source, that *"the Engine can route
Terminal execution to a DeskPilot-owned backend"*. It cannot. `run_command` is a
built-in Engine Tool that spawns its child process itself; DeskPilot sees the
call only as a `ToolCall` progress record, which `ConvertTo-DpActivityAction`
turns into an Activity row **after** the fact. Inferring control from
post-execution Activity is exactly what the prompt forbids.

So isolation needs the *same* upstream Engine contract as approval: an optional
DeskPilot-supplied executor invoked before the command runs. Shipping isolation
before that would mean re-implementing `run_command` as a User Tool and hoping
the Model prefers it over the built-in — a boundary the Model can decline, which
is not a boundary.

## Backend comparison

Assessed against the prompt's criteria for a Windows-first, CurrentUser,
no-elevation product.

| Backend | Windows | Dependency burden | Mounts | Cancellation | Network control | Credential isolation | Cleanup | Verdict |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| **Windows Sandbox** | Pro/Enterprise only, needs Hyper-V + an admin feature install | Ships with Windows | `<MappedFolder>` per-folder, read-only supported | No process API; the whole sandbox is the unit | `<Networking>Disable</Networking>` only — all or nothing | Clean: fresh profile, no ambient tokens | Disposable by construction | **Rejected**: Home editions excluded, elevation to enable, and no per-command cancellation |
| **Docker Desktop / WSL2** | Yes, but a large third-party install with licence terms | ~1 GB plus a WSL2 distro | Bind mounts, `:ro` supported, well understood | `docker kill` terminates the tree | `--network none` plus an explicit allow-list proxy | No ambient host credentials unless mounted | `--rm` plus a reaper | **Preferred** if a dependency of this size is acceptable |
| **Hyper-V VM** | Pro/Enterprise, elevation, minutes to start | Very large | Slow (SMB/9p) | Yes | Full | Full | Heavy | **Rejected**: start-up cost defeats a per-command boundary |
| **Job objects / AppContainer** | Native, no dependency | None | **None** — the host file system stays fully visible | Yes | None | None | Trivial | **Rejected as isolation**: it bounds CPU/memory, not reach. Calling it isolation would be the exact mis-marketing the prompt forbids |
| **Remote SSH host** | Needs a second machine | Operational, not local | rsync/sftp round-trips | Yes | Yes, at the remote's firewall | Yes | Manual | **Deferred**: viable for a team, wrong shape for a single-user desktop app |

**Decision (conditional on the gate opening):** Docker via WSL2, mounting only
the selected Project (`:ro` by default), `--network none`, no `-e` pass-through
except an explicit per-variable allow-list, pinned digest-addressed base image,
`--rm`, and `docker kill` on Stop. Windows Sandbox is the fallback for machines
that already have it and where per-command cancellation can be relaxed.

## Prerequisite list

1. Engine contract from `specs/120` shipped — an optional pre-execution callback
   DeskPilot can answer with allow/deny **and** with a substitute executor.
2. Per-call approval implemented on top of it, with correlated fingerprints.
3. A Diagnostics probe for backend presence, version and orphaned containers.
4. A decision on the dependency: DeskPilot currently installs nothing beyond two
   PowerShell modules, and Docker Desktop is a different order of commitment.
5. A hostile-workload test corpus (a build script that reads `$HOME`, resolves
   cloud metadata, opens a socket, and follows a junction out of the mount).

## What was deliberately not done

No `Local`/`Isolated` mode toggle, no container code, no Settings key, and no UI
affordance. A visible mode switch that does not actually contain anything is
worse than its absence: it converts an honest limitation into a false promise.
