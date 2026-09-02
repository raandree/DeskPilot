---
schema-version: 1
status: accepted
owner: shared
last-verified: 2026-09-02
source: repository evidence
---

# Active Context

## Current focus

**Diagnostics, live Host Server logs, deterministic Self-check, and a redacted
Support bundle are implemented on `ai/competitive-landscape-2026`.** The user
explicitly asked to work on the current branch. No branch was created or
switched, and nothing was pushed.

The sidebar and command palette open a calm Diagnostics modal. It reports
DeskPilot, PowerShell, Engine, Git, and operating-system versions; the resolved
data and Engine module paths; active Project; Engine loading/authentication;
MCP, Intercom, and Update state; and the latest Self-check. Every check is one
of `healthy`, `degraded`, `unavailable`, or `not configured`, with a bounded
explanation and at most one safe next action.

## Runtime design

- `New-DpDiagnosticSnapshot` creates an allow-listed state record. It never
  serializes live Settings, Conversations, Messages, Attachments, Tool
  arguments, credentials, cookies, authorization headers, or environment
  values.
- `Start-DpDiagnosticCheck` runs the worker in a background PowerShell job.
  Each local path/Git probe has a stoppable 1.5-second default deadline. The
  worker invokes no Model, Engine command, or network endpoint and writes no
  user data, so it cannot consume Copilot credits.
- The Host Server owns a synchronized in-memory ring capped at 500 entries and
  1 MiB. Each record has sequence, timestamp, severity, component, event id,
  and a redacted summary. Sequence remains monotonic across clear. The browser
  polls by cursor every two seconds only while Diagnostics is open and keeps at
  most 500 rows itself.
- The support archive contains exactly `summary.md`, `diagnostics.json`, and
  `host-log.jsonl`, generated directly into a ZIP with no staging tree. Input
  is capped at 2 MiB and the final archive at 3 MiB. The destination is a new
  direct child of `<DataDir>/support-bundles`; traversal, reparse points,
  overwrite, over-size output, and concurrent export are refused.

## Security posture

Redaction is by construction. Support records copy only approved fields;
unknown fields are absent. Known DeskPilot roots become `<purpose:leaf>` and
other Windows, UNC, or POSIX absolute paths become `<path:leaf>`. The local
Diagnostics response deliberately retains only two absolute paths: DeskPilot
data and Engine module, because verifying those paths is the local diagnostic.

All `/api/*` requests now require a loopback Host header and, when Origin is
present, the same HTTP loopback host and port. This complements the existing
loopback listener and per-launch session token. Error logging is StrictMode-safe
even before Diagnostics or Intercom state is initialized.

## Verification

- Red-first Diagnostics tests cover count/byte retention, ordering, clear,
  cursor polling, 200 concurrent appends, secret and Message exclusion, unknown
  field exclusion, dependency-state mapping, probe failure/timeout, no Model or
  network calls, no file mutation, asynchronous job/reaping, valid ZIP content,
  collision/path/reparse/overwrite/size/concurrency defenses, StrictMode, and
  Origin/session-token gating. Focused result: **48/48**.
- WebAssets tests cover the modal, controls, four-state mapping, bounded polling,
  safe destination display, responsive styles, and pure log merging:
  **52/52**.
- MCP observation integration: **67/67**; combined Diagnostics + MCP gate:
  **115/115**.
- AST: 28 changed PowerShell files, 0 parse errors. PSScriptAnalyzer: 0 new
  findings; the one BOM warning on `Invoke-DpRouteHandler.ps1` reproduces on
  `HEAD`. JavaScript syntax, editor diagnostics, diff whitespace, Markdown for
  new/edited feature docs, and guide targets are clean.
- Final frozen-source Sampler gate: **1484/1484**, 16 tasks, 0 errors, 0
  warnings. The built package contains the Diagnostics asset, modal, 13
  diagnostic functions, and three Support bundle functions.
- Live loopback smoke on the final build: modal `200`, self-check start `202`,
  10 completed checks with honest MCP `not configured`, and a bounded log. A
  real 2,392-byte Support bundle contained exactly `summary.md`,
  `diagnostics.json`, and `host-log.jsonl`, with neither the session token nor
  the absolute data path.

## Close-out

Commit the complete change on the current branch with the required AI co-author
trailer, and do not push. Because this change touches the shared API security
boundary and generated support archives, recommend `review: on` for an
independent security review.
