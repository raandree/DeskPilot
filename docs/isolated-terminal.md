# Isolated Terminal execution

DeskPilot can run Terminal commands in disposable Linux containers on Windows.
This optional boundary applies only to the Terminal Tool. File, Browsing, MCP,
Intercom, the Model, and the Host Server retain their existing authority.

## Prerequisites

- Windows with PowerShell 7.4 or newer for the Host Server.
- Docker Desktop using its local Linux amd64 daemon and WSL2, installed by the
  operator. Docker Desktop licensing and virtualization requirements apply.
  DeskPilot never installs or removes Docker or WSL.
- A ShellPilot build that refuses disabled built-in Tools. DeskPilot checks this
  capability before registering its Terminal Tool. Development proofs use staged
  ShellPilot 0.4.1; the installed 0.4.0 does not satisfy the gate. A clean install
  needs a compatible Engine separately until it is published.
- A selected local Project. Drive roots, the home directory, UNC paths, linked
  Project ancestors, and ambiguous mount paths are refused.

## Setup and selection

1. Open **Diagnostics**, **Terminal runtime**, then **Prepare runtime**. Confirm
   the download and local image build. Preparation runs separately from Turns.
2. Run **Check**. It verifies the Docker daemon, prepared image identity, runtime
   version, source hashes, and remaining owned containers.
3. Open **Settings**, **Permissions**, **Terminal execution**. Select **Isolated**,
   choose Project access and network policy, then save. Terminal and User Tools
   Permissions must both be on to run commands.

Existing Settings default to **Local**. No dependency error, approval denial,
proxy failure, or cleanup failure switches back to Local. Policy edits apply to
the next Turn, not to a pending approval. Non-routine commands require individual
approval in Isolated mode even when Local approval is off.

## Files and credentials

The Project is mounted at `/project`, read-only by default. Working directories
must remain inside it. The image filesystem is read-only; temporary files use
bounded container storage. There is no home-directory mount, host drive alias,
host device, credential-store mount, SSH agent, or Docker control socket.

Read-write access is an explicit choice. Existing Project links and hard-linked
files are refused for read-write commands. Direct Project Git metadata is mounted
read-only to protect the snapshot history used by Undo. Change accounting is
bounded to 50,000 entries, 100 MiB per file, 512 MiB total, and 15 seconds per
scan. Larger Projects need read-only execution or a smaller Project.

Project-relative changed paths join pending changes and Undo. The pre-Turn
snapshot remains the recovery source. Git-ignored files may be reported but not
restorable from Git. Avoid simultaneous outside edits: before/after accounting
cannot attribute them to a particular author.

Environment grants contain names and secret markers only. Values are resolved
by the Host Server, not saved in Settings, exported in backups, or shown on
approvals. Known secret values are replaced in returned output. This is not
general data-loss prevention: a granted secret is available to the command, and
transformed data or secrets already in the Project cannot be assumed harmless.
Keep secret grants empty unless required.

## Network policy

**Off** is the default and uses Docker's `none` network.

**HTTPS allow-list** permits exact public DNS names on port 443, not subdomains.
The trusted controller resolves approved names before the command and pins their
public IPv4 addresses. Namespace-local packet rules deny direct command TCP,
DNS, UDP, IPv6, local-service, and metadata access. Clearing proxy environment
variables does not remove that enforcement.

Squid inspects HTTPS with a temporary CA trusted only inside the disposable
command container. Client-side TLS is established before upstream contact, so
HTTP authority can be checked first. Origin certificate verification stays on.
The proxy has no Project mount or host credentials; its private CA key remains
in its own bounded temporary storage. Windows and browser certificate stores
are unchanged. Proxy access/content logging and caching are disabled.

SSH, arbitrary TCP, UDP, QUIC, mutual TLS, certificate-pinned clients, and clients
that refuse the temporary CA fail visibly. There is no direct-network fallback.
An allowed origin can receive data deliberately sent to it: the policy does not
distinguish accounts, URL paths, methods, or content at an approved origin.

## Resource limits

| Resource | Default | Range or limitation |
| --- | --- | --- |
| Command time | 120 seconds | 1-3,600 seconds; a Tool timeout can only shorten it. |
| CPU | 1 CPU | 0.1-8 CPUs; quota throttles rather than immediately failing. |
| Memory | 1,024 MiB | 256-8,192 MiB, with no additional swap allowance. |
| Processes | 64 | 16-256 tasks counted by the container process controller. |
| Combined output | 1 MiB | 1 KiB-16 MiB; exceeding it fails visibly. |
| Temporary storage | 128 MiB | 16-1,024 MiB. |
| Read-write Project disk | No total quota | Temporary-storage limits do not bound Project writes. |

The proxy has separate fixed limits: 256 MiB memory, 0.5 CPU, 64 processes,
32 MiB policy/certificate storage, and 16 MiB temporary storage. Startup, Windows
file sharing, and TLS inspection add work per command. There is no performance
parity claim with Local execution.

## Stop, recovery, and removal

**Stop** cancels the controller before stopping the Engine pipeline. Cleanup
removes command and proxy containers, including descendants, then verifies their
absence. Failed cleanup remains visible and blocks further Isolated work.

After a killed Host Server or Docker failure, use **Diagnostics**, **Terminal
runtime**, **Clean up**. Cleanup matches the ownership label, generated name,
and owning process. It does not prune globally or stop another live DeskPilot
process's containers. Containers and private CAs are never reused across commands.

To roll back, stop active work, clean up environments, explicitly select **Local**,
and save. This does not undo read-write Project changes; use pending changes or
Checkpoints. **Remove runtime** removes this installation's image tag and
provenance record, not Docker, WSL, shared base layers, or Project files. Dependency
removal is a separate operator action because other workloads may use them.

## Provenance and verification

Preparation uses a digest-pinned MCR base and verifies the official PowerShell
7.6.5 archive against its recorded SHA-256. Packages come from distribution
repositories. The resulting immutable image identity, runtime version, archive
hash, bundled source hashes, and package inventory are recorded under DeskPilot's
data directory. Turns use that identity with `--pull never`. Re-prepare after
runtime source changes or to acquire package security updates.

Integration tests exercise the real registered Tool and Docker with temporary
Projects and fresh containers. They cover positive HTTPS access, denials,
resource exhaustion, approvals, Stop with descendants, links, archive traversal,
environment grants, and change accounting. Unit tests cover policy validation,
Engine dispatch, Turn preflight, and routes. Playwright checks desktop/mobile
controls and approval rendering. Backend-unavailable skips are not release proof.

The final local Sampler gate passed 2,286 tests with no failures; five unchanged
browser Unicode cases were skipped, not isolation tests. All 29 real-container
isolation cases ran and passed. Independent review identified a protocol gap:
host/443 rules alone admitted plain HTTP and direct non-CONNECT proxy requests.
Explicit encrypted HTTPS/CONNECT checks now reject both, with red/green proofs.

The HTTP smoke verifies approval, Activity, Engine Usage mapping, pending changes,
and Undo with a scripted provider as well as real Engine dispatch and Docker.
The live Copilot profile remains unverified because sign-in requires renewal.
Do not treat its scripted token counts as provider billing or live acceptance.

This is container isolation, not a separate VM-grade boundary. It does not defend
against a compromised Docker daemon, Host Server, or shared WSL kernel.

## See also

- [Architecture](../specs/020-architecture.md).
- [API contract](../specs/030-api-contract.md).
- [Security model](../specs/050-security-model.md).
