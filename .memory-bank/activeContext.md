---
schema-version: 1
status: accepted
owner: software-engineer
last-verified: 2026-09-30
source: red/green Node regressions, Pester web-asset contracts, and headless Edge loopback journeys
---

# Active context

## Current focus

DeskPilot now draws its own icons, like the VS Code chat screenshot the user
shared, instead of emoji. This is on `ai/thinking-scroll-titles`, after
the scroll/title fix (`2cb8948`) and the rate-update record (`420e3d2`). No push
or Merge was requested.

- `source/web/assets/icons.js` holds 19 original 16px stroke drawings in
  currentColor. `iconSvg(name)`/`iconKey(name)` accept names only; unknown or
  inherited names draw `tool`. `iconHtml`/`setIcon` in `app.js` fill `.ico` slots.
- Activity kinds carry an `icon` name (the new `browse` kind reads `Browsed`).
  Working/Activity, Tasks, Changes/live edits and Steps headers carry icons.
- Thinking boxes: live = accented thought bubble with pulsing bubbles and a
  shimmering label. When a box seals, `summarizeThinking` returns `{ title, icon }`.
  Tool-only runs use `TOOL_KINDS`, a mirror of `ConvertTo-DpActivityAction`
  guarded by `icons.test.mjs`, to show the kind icon and verb.

## Validation

- 91/91 Node UI tests; 720 Pester cases with six environment skips.
- Headless Edge loopback fixtures with the real SPA: icon suite 28/28 (dark,
  light, Terminal Green, 390 px), scroll/jump regression 16/16, reduced motion
  and forced colours checked. Not a live Engine run.

## Earlier on this branch

The rates for `claude-opus-5.5` and the other advertised Models were updated
upstream in ShellPilot `ai/update-price-table` @ `4096260` (worktree
`D:\Git\ShellPilot-price-table`). DeskPilot shows the costs once that Engine is
installed, and prepared private-child proof must then be renewed.

## Retained boundaries

Terminal-only approval remains the default. Permissions, isolation and child
opt-in are unchanged; source-bound child proof is invalidated by source changes
and must be renewed before enablement. Parallel topology remains unapproved.
Memory provenance and per-Project scope remain Host-controlled. Keep a private
copy of version-2 Memory before downgrade; never promote confidential notes to
global scope merely to retain them in an older build. Never price Models in
DeskPilot; fix a missing or stale rate in ShellPilot's price table.
