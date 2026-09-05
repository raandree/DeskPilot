---
schema-version: 1
status: accepted
owner: shared
last-verified: 2026-09-05
source: repository implementation and executable verification
---

# Active context

## Current focus

Optional isolated Terminal implementation is complete on
`ai/isolation-dependency-decision`; the local commit records this closure. No push or
publication is authorized. The operator requested autonomous completion and
retained working nonempty outbound allow-lists after rejecting an offline-only
proposal. No production Settings or host certificate trust was changed.

## Implemented

- Local remains the default. Isolated always owns `run_terminal_command`, keeps
  non-routine approval required, and refuses a non-enforcing Engine even with
  Terminal Permission off. No dependency error silently selects Local.
- Docker Desktop/WSL2 command containers are disposable, non-root, network-off
  by default, and mount only the selected Project. Explicit read-write access
  feeds Project-relative changes into pending changes and Undo.
- Exact HTTPS allow-lists use namespace-local packet rules and a disposable
  client-first TLS-inspecting Squid proxy. Direct TCP/DNS/UDP/IPv6 is denied.
  CA trust is container-local. Origin certificates remain verified.
- Settings, approvals and Activity show execution policy. Environment grants
  persist names/secret markers, not values. Time, CPU, memory, process, output
  and temporary-storage limits are enforced. Read-write Project disk has no
  total quota; other Tools are not isolated.
- Diagnostics prepares, checks, cleans up, and removes the owned runtime.
  Preparation is asynchronous, and Turns never download an image. Runtime
  provenance includes verified PowerShell 7.6.5 bytes and immutable image ID.
- Stop removes the command/proxy pair, including descendants. A proxy crash
  stops the command. Cleanup failure is visible and blocks further work.

## Final evidence

- Full Sampler `build,test`: **2286 passed, 0 failed, 5 skipped**, 16 tasks,
  zero build errors/warnings. The five skips are unchanged browser Unicode
  cases with a discovery-time Node flag; no isolation proof was skipped.
- Real Docker/Engine integration: **29 passed, 0 failed, 0 skipped**. Includes
  positive HTTPS, protocol/Host denials, resource exhaustion, Stop, links,
  archive traversal, environment grants, missing image, failed cleanup and
  asynchronous setup.
- Independent security review: **0 Blockers, 1 Major**. MAJOR-01 was reproduced
  and fixed with explicit CONNECT/encrypted-connection/HTTPS ACLs. Four protocol
  checks passed after the fix. Squid 5 uses `connections_encrypted`.
- Deterministic HTTP acceptance passed through the real built Host Server,
  Engine dispatch, approval bridge and Docker. Exactly one command was approved;
  Activity and Engine Usage mapping were verified, and Undo preserved an
  existing user edit. Provider responses were explicitly scripted, not live.
- Playwright policy saving, early Settings open, desktop/mobile rendering and
  overflow checks passed. No owned Terminal containers remain after tests.

## Release limits

The real Copilot smoke reached runtime readiness but `/api/models` returned
`auth_required`. The operator must reauthenticate before a live Model/operator
acceptance run can finish. No credentials were requested through chat.

A separate preview runs on port 57661 with temporary data and Local defaults.
It uses the real Engine, not the scripted acceptance fixture, and still needs
the operator's normal Copilot sign-in to run live work.

Staged ShellPilot 0.4.1 enforces disabled Tools; installed 0.4.0 does not. A
compatible obtainable Engine remains a clean-install release dependency. Do not
describe deterministic fixture Usage as real billing or this state as published.

See [setup and limitations](../docs/isolated-terminal.md) and
[decision 0001](decisions/0001-isolated-tool-execution.md).

## Earlier work

Contained browser automation remains implemented and independently reviewed.
Its detailed mutation, hostile-site and live-workflow evidence, residual risks,
and older isolation-dependency investigations are preserved in
[the archived active context](archive/active-context-2026-09-05.md).
