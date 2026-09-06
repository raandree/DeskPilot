---
schema-version: 1
status: accepted
owner: technical-writer
last-verified: 2026-09-06
source: repository documentation and operator review confirmation
---

# Documentation registry

Record completed writing deliverables without implying a public release.

## 2026-09-06 - Isolated Terminal operator guide

- Deliverable: [Isolated Terminal execution](../docs/isolated-terminal.md),
  expanded with user-visible impact, migration, return to Local, and removal.
- Audience: operators deciding whether to opt in and how to recover their work.
- Status: final technical-writer stage closed locally after the operator reported
  the review passed; the implementation baseline is `f6af6fd`.
- Release note: refined the existing [Unreleased entry](../CHANGELOG.md), keeping
  Local as the default and Project writes separate from runtime disposal.
- Primary sources: [policy defaults](../source/Private/ConvertTo-DpTerminalExecution.ps1),
  [runtime removal](../source/Private/Remove-DpTerminalRuntime.ps1),
  [UI policy presentation](../source/web/assets/app.js), and
  [decision 0001](decisions/0001-isolated-tool-execution.md).
- Verification: guide and changelog render; local links resolve. Executable test
  evidence is retained from the unchanged implementation, not rerun here.
- Release follow-ups: live authenticated acceptance and availability of an
  enforcing Engine for clean installations. No push or publication.
- Reusable structure: [optional-execution guide pattern](writing-patterns.md).
