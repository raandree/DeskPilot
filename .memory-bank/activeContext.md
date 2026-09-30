---
schema-version: 1
status: accepted
owner: software-engineer
last-verified: 2026-09-30
source: GitHub Models and pricing page, live Engine model list, ShellPilot and DeskPilot test runs
---

# Active context

## Current focus

Model rates were requested "in this branch" after DeskPilot showed `cost
unknown` for `claude-opus-5.5`. Pricing stays Engine-owned, so the rates were
updated upstream in ShellPilot, not in DeskPilot: branch
`ai/update-price-table` in the separate worktree `D:\Git\ShellPilot-price-table`,
cut from ShellPilot `origin/main` at `08a4a22`. The main ShellPilot checkout
stays on `ai/agent-modernization`. No push, Merge or release was requested.

- The table matches all 47 Model/tier rows of the GitHub page read on
  2026-09-30 and prices every picker-enabled chat Model the service advertised
  that day, except the internal-only `gpt-5.6-sol-fast`, which has no published
  rate and stays `cost unknown`.
- DeskPilot uses the highest installed ShellPilot and never updates an
  installed one. Costs appear only after an Engine containing the new table is
  installed or passed with `-EngineModulePath`. That changes the Engine's
  `data/PriceTable.psd1` bytes, so prepared private-child proof must be renewed.

## Earlier change on this branch

`2cb8948` keeps the live thinking section scrollable and titles completed
sections by content. Its evidence: 82/82 Node UI tests, 719 Pester cases with
six environment skips, and headless Edge journeys 16/16 new versus 10/16 old.

## Retained boundaries

Terminal-only approval remains the default. Permissions, isolation and child
opt-in are unchanged; source-bound child proof is invalidated by source changes
and must be renewed before enablement. Parallel topology remains unapproved.
Memory provenance and per-Project scope remain Host-controlled. Keep a private
copy of version-2 Memory before downgrade; never promote confidential notes to
global scope merely to retain them in an older build. Never price Models in
DeskPilot; fix a missing or stale rate in ShellPilot's price table.
