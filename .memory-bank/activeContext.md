---
schema-version: 1
status: accepted
owner: shared
last-verified: 2026-09-06
source: repository evidence and operator review confirmation
---

# Active context

## Current focus

The optional isolated Terminal cycle reached its final technical-writer stage on
2026-09-06. Design, implementation, review, and documentation are closed locally
on `ai/isolation-dependency-decision`. The implementation remains `f6af6fd`;
this closeout changes documentation only, not source, tests, or build settings.

The operator confirmed that the review passed and requested this handoff. That
confirmation is the review acceptance for this stage, not a new independently
executed review. Live authenticated acceptance and a clean-install Engine remain
separate release gates below. No push, publication, version change, production
Settings change, or host certificate trust change is part of this closeout.

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

## Implementation evidence from 2026-09-05

These results are retained from the implementation baseline. Pester, Sampler,
Docker, and Playwright suites were not rerun for the documentation-only stage.

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

## Documentation closeout

- Expanded the [operator guide](../docs/isolated-terminal.md) with visible mode
  differences, existing-user compatibility, Linux workflow migration, and
  explicit return-to-Local and runtime-removal steps.
- Clarified the existing Unreleased entry without adding a release or changing
  versions. Runtime removal and returning to Local do not undo Project writes.
- Markdown rendering and local-link checks passed. No executable verification
  required. Existing changelog duplicate-heading and blank-line diagnostics are
  outside the changed entry and were not altered.
- The [writer registry](article-registry.md) records the deliverable and sources.

## Release limits

The last real Copilot smoke reached runtime readiness but `/api/models` returned
`auth_required`. Renew sign-in and rerun live Model/operator acceptance before
claiming that gate passed. This stage did not attempt authentication or confirm
whether the earlier temporary preview is still running.

The recorded proofs used staged ShellPilot 0.4.1, which enforces disabled Tools;
the installed 0.4.0 failed that gate. A compatible obtainable Engine remains a
clean-install release dependency. Do not describe deterministic fixture Usage
as real billing or this state as published.

See [setup and limitations](../docs/isolated-terminal.md) and
[decision 0001](decisions/0001-isolated-tool-execution.md).

## Earlier work

Contained browser automation remains implemented and independently reviewed.
Its detailed mutation, hostile-site and live-workflow evidence, residual risks,
and older isolation-dependency investigations are preserved in
[the archived active context](archive/active-context-2026-09-05.md).
