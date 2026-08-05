---
schema-version: 1
status: accepted
owner: shared
last-verified: 2026-08-05
source: repository evidence
---

# Active Context

## Current focus

**The Project chip shows the selected Workspace Folder leaf (2026-08-05; local
branch `ai/fix-project-chip-label`, not pushed).** The chip previously rendered
the stored Project name, so a stale value such as `d:` appeared even when the
selected path was `D:\ling`. It now derives the visible text and hover title
from `leafName(selected.path)`.

The button is explicitly content-sized. Short leaf names keep it compact; the
label caps at 150 px and uses CSS ellipsis for longer names while retaining the
full leaf in the tooltip.

## Verification

- TDD red baseline reproduced `d:` instead of `ling`; focused WebAssets tests
  then passed **9/9**.
- Headless Chrome measured the chip growing from **76.7 px** to **208.0 px**;
  the long label had 293 px of content in a 150 px box with computed
  `text-overflow: ellipsis`, and the full tooltip remained available.
- Complete `app.js` ESM parse passed; edited-file diagnostics and
  `git diff --check` were clean.
- Full Sampler test task passed **427/427**: 9 tasks, 0 errors, 0 warnings.

## Next step

Refresh the running DeskPilot page to use the corrected chip. Do not push the
local branch without an explicit request.
