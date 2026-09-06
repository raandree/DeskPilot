---
schema-version: 1
status: accepted
owner: technical-writer
last-verified: 2026-09-06
source: repository glossary and operator documentation
---

# Editorial style guide

Current conventions for DeskPilot operator guides, grounded in the
[Isolated Terminal guide](../docs/isolated-terminal.md).

## Audience and terminology

- Write for operators choosing Permissions and reviewing effects on their files.
- Use the [canonical glossary](glossary.md), including Engine, Model, Project,
  Turn, Activity, and Usage. Distinguish Keep, Save, Undo, and Checkpoint.
- Use sentence-case headings, numbered procedures, and exact UI labels in bold.
  Link to existing setup and architecture documents instead of duplicating them.

## Claims and evidence

- State defaults, explicit choices, and the affected Tool before implementation
  detail. Do not imply Terminal isolation covers every Tool.
- Pair guarantees with limits, including persistent Project writes and the
  difference between origin allow-lists and data-loss prevention.
- Date measured evidence. Distinguish a user-confirmed review pass from a new
  independent review, and scripted Usage from live provider billing.
- Keep cycle administration in the Memory Bank. Keep operator guidance focused
  on setup, use, recovery, and release prerequisites.
