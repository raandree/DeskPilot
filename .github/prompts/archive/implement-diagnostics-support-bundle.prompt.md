---
description: "Implement DeskPilot diagnostics, live logs, and a redacted support bundle"
agent: "software-engineer"
---

# Implement diagnostics and a support bundle

## Why this feature is useful

DeskPilot spans the browser, Host Server, Engine, MCP servers, Git, updates, and
Intercom. A single diagnostics surface turns failures across those boundaries
into evidence a non-technical user can understand and safely share.

## Use case

An analyst sees that an MCP Tool never becomes available. They open Diagnostics,
run a self-check, see that the server executable cannot be found, and export a
redacted support bundle containing versions and status without prompts, document
contents, access tokens, or environment-variable values.

## Objective

Implement a read-only Diagnostics surface, bounded live Host Server log, a
deterministic self-check, and an explicitly generated redacted support bundle.
The self-check must not invoke a Model or consume Copilot credits.

## Required context

Read `specs/020-architecture.md`, `specs/030-api-contract.md`,
`specs/040-ui-design.md`, `specs/050-security-model.md`, and the diagnostic and
redaction patterns in `.memory-bank/systemPatterns.md`. Trace existing health,
Engine, update, MCP, Intercom, transcript, and error-reporting paths before
choosing new state or routes.

## Required behavior

- Report DeskPilot, PowerShell, Engine, Git, and operating-system versions;
  resolved data/module paths; active Project status; Engine authentication
  status; MCP server status; Intercom status; update status; and last self-check
  time.
- Distinguish `healthy`, `degraded`, `unavailable`, and `not configured`, with a
  bounded explanation and one safe next action.
- Add a fixed-capacity in-memory log ring owned by the Host Server. Include
  timestamp, severity, component, event id, and redacted summary.
- Stream or poll new log entries without blocking the single-threaded accept
  loop. Preserve Stop responsiveness during a Turn.
- Make retention explicit by entry count and byte ceiling. Clear the ring on
  user request and Host Server restart; do not silently persist it.
- Add a deterministic self-check that exercises configuration and local
  dependencies without mutating user data or starting a Model Turn.
- Export one bounded archive with a human-readable summary and structured data.
  Generate it only on explicit user action and show its destination.
- Include configuration shape and enabled-state metadata, never secret values.
- Make unavailable checks honest. Do not report success when a dependency could
  not be inspected.

## Redaction and security boundaries

- Construct export records from field allow-lists. Do not serialize live state
  objects and then attempt pattern-based cleanup.
- Exclude prompts, answers, reasoning, file contents, diffs, Attachments,
  Message history, raw Tool arguments, tokens, cookies, authorization headers,
  remote URLs containing credentials, and environment-variable values.
- Represent sensitive paths as purpose plus leaf name when the absolute path is
  not required for diagnosis. Document every absolute path that remains.
- Pass errors through existing secret-hiding helpers before logging.
- Defend archive creation against path traversal, symlink/junction redirection,
  overwrite, unbounded growth, and concurrent export requests.
- Require the normal loopback, origin, and session-token controls for every
  diagnostics route.

## Test-first proof

Write failing Pester tests before production changes. Cover at least:

- Ring capacity, byte bounds, ordering, clear, and concurrent append behavior.
- Known secrets and Message content never appear in API results or exports.
- Unknown fields are excluded by construction.
- Each dependency state maps to the correct diagnostic state and action.
- Self-check performs no Model call, file mutation, or network action beyond
  explicitly documented read-only probes.
- Export is valid, bounded, collision-safe, and refused outside its allowed
  destination.
- A slow or failing probe times out and reports `degraded` without freezing the
  Host Server.
- Live viewing does not delay SSE Turn streaming or Stop.

## Definition of done

- Add a calm Diagnostics view using the existing design language; avoid a raw
  developer console as the primary experience.
- Update API contract, UI design, security model, user documentation, and
  roadmap with fields, bounds, retention, and failure behavior.
- Run focused Pester tests, parsing, PSScriptAnalyzer, JavaScript syntax checking
  when applicable, and `./build.ps1 -Tasks build, test`.
- Update `CHANGELOG.md` and the routed Memory Bank records.
- Commit on a focused topic branch. Do not push.

## Non-goals

- Telemetry or automatic upload.
- Persisting an unbounded log file.
- Including user content for convenience.
- Repair actions hidden behind a health check.
- A Model-generated diagnosis presented as a deterministic result.