---
description: "Implement optional isolated Terminal execution for DeskPilot"
agent: "software-engineer"
---

# Implement optional isolated Tool execution

## Why this feature is useful

Approval lets a user reject a visible risky action, but it cannot contain a
malicious dependency or an approved command with unexpected effects. Optional
isolation limits what Terminal execution can reach even when the Agent is
prompt-injected or a command behaves badly.

## Use case

An analyst asks DeskPilot to inspect an unfamiliar repository. They select
Isolated execution, which mounts only that Project into a disposable environment,
passes no ambient credentials, blocks network access by default, and shows the
boundary beside every command. A compromised build script cannot read the home
directory or silently upload files.

## Objective

Add one optional execution boundary beneath the Terminal Tool without replacing
the Engine. Start with Terminal only and one proven local container or remote
backend selected through an approved architecture decision.

## Prerequisite gate

Confirm per-call approval is implemented and enforced before proceeding. If it
is absent, stop after producing the architecture decision and prerequisite list;
do not ship isolated execution as a substitute for action-level approval.

## Required context

Read `specs/020-architecture.md`, `specs/030-api-contract.md`,
`specs/040-ui-design.md`, `specs/050-security-model.md`, and the Engine,
Permission, Activity, and hardened command-runner patterns in
`.memory-bank/systemPatterns.md`. Trace how Terminal Tools are registered and
executed in the Engine. Verify that the Engine can route Terminal execution to a
DeskPilot-owned backend before changing production code; do not infer control
from post-execution Activity.

Create a decision record comparing the viable backends against Windows support,
dependency burden, mount semantics, process cancellation, network control,
credential isolation, performance, cleanup, and rollback. Get the decision
approved before implementation.

## Required behavior

- Offer explicit `Local` and `Isolated` execution modes with an unambiguous
  active-state indicator beside Terminal Permission and command approvals.
- Keep Local behavior backward compatible and never switch modes silently.
- Mount only the selected Project by default. Make read-only versus read-write
  mode explicit and default to the least privilege that supports the task.
- Start with no home-directory mount, host socket, device access, credential
  store, SSH agent, cloud metadata identity, or inherited environment.
- Pass environment variables through an explicit per-variable allow-list. Mark
  secret values without displaying or logging them.
- Default network egress to off. If the chosen backend cannot enforce network
  policy, state that limitation in the UI and do not call the mode isolated.
- Map the working directory predictably and translate Activity paths back to
  Project-relative paths without weakening pending changes or Undo.
- Apply time, CPU, memory, process, output, and disk limits where supported.
- Stop must terminate the complete isolated process tree and release resources.
- Make environment lifecycle explicit: disposable by default, with no persistence
  unless separately designed and approved.
- Detect missing or unhealthy backend dependencies before a Turn starts.

## Security boundaries

- Apply the lethal-trifecta test assuming the Agent is already prompt-injected.
- Break the private-data leg with narrow mounts and no ambient credentials; break
  the outbound leg with default-deny egress.
- Never mount the container or remote control socket into the environment.
- Prevent path escapes through symlinks, junctions, mount aliases, archives, and
  case differences.
- Treat environment output as untrusted Tool data, not instructions.
- Pin and verify base images or remote runtime versions. Record provenance.
- Never market process-level wrapping as isolation if host files and network
  remain unrestricted.

## Test-first proof

Write failing integration tests against the chosen backend. Cover at least:

- The Project is reachable with the declared access and unrelated host paths are
  not reachable.
- Ambient tokens, credential stores, environment variables, and metadata
  identities are absent.
- Network is denied by default and an explicit allow-list behaves narrowly.
- CPU, memory, disk, process, output, and timeout bounds fail visibly.
- Stop kills descendants and cleanup leaves no running environment or mount.
- Local and Isolated modes produce accurate Activity, Usage, pending changes,
  and approval behavior.
- Backend unavailable, startup failure, crash, and cleanup failure states.
- Crafted paths and links cannot escape the Project mount.

Run tests in a clean environment and skip only with an explicit unavailable-
backend reason; a skipped isolation suite is not release evidence.

## Definition of done

- Update architecture, API contract, UI design, security model, setup guidance,
  and roadmap with guaranteed and unsupported isolation properties.
- Add Diagnostics checks for backend availability, version, and cleanup health.
- Run focused unit/integration tests, the full Sampler gate, and an independent
  security review before release.
- Document migration, rollback to Local mode, resource cleanup, and dependency
  removal.
- Update `CHANGELOG.md` and routed Memory Bank records.
- Commit on a focused topic branch. Do not push.

## Non-goals

- Replacing the Engine.
- Claiming complete VM-grade isolation from a weaker backend.
- Isolating File, Browsing, MCP, or Intercom in the first slice.
- Cloud execution or shared multi-user environments.
- Persistent containers with hidden state.