---
schema-version: 1
status: accepted
owner: software-engineer
last-verified: 2026-09-29
source: red/green Node regressions, Pester web-asset contracts, and headless Edge loopback journeys
---

# Active context

## Current focus

The thread could not be scrolled back down to the running thinking section
while reasoning streamed, and completed sections said only `Thought for Ns`.
Both are fixed on topic Branch `ai/thinking-scroll-titles`, cut from `main` at
`4c9cda4` (already on `origin/main`). No push or Merge was requested.

## Latest change

- Root cause: `renderThinking` pinned the live section with a script scroll on
  every token; in Chromium that cancels the reader's wheel scroll of the thread.
  The live body is now clipped and bottom-aligned in CSS and never scrolled.
- An upward wheel stops following at once; scrolling back to the bottom resumes
  it. A ↓ control (`#thread-jump`, i18n `thread.jump`) appears above the
  composer while the reader is away from the newest output.
- `thinkingTitle` labels completed sections from their own text: the model's
  heading, else its opening sentence (past short openers), else the Tool calls.
  The duration sits beside the title. Plain text only; no Model call.
  Stored sections get titles without an invented duration.

## Validation

- Six new Node cases failed first; 18 focused and 82/82 Node UI tests pass.
- Pester 6.2.0, isolated: WebAssets, Localization, BrowserAutomation and
  SkillConformance pass 719 with six symlink/case-sensitivity environment skips.
- Headless Edge journeys against a loopback SSE fixture using the real SPA pass
  16/16 on the new assets and fail 6/16 on the old ones (3 px stall, no titles).
  Desktop and 390 px mobile; no page errors or off-loopback requests. Headless
  wheel input has no smooth animation, so one-notch follow is Node-proved.

## Retained boundaries

Terminal-only approval remains the default. Permissions, isolation and child
opt-in are unchanged; source-bound child proof is invalidated by source changes
and must be renewed before enablement. Parallel topology remains unapproved.
Memory provenance and per-Project scope remain Host-controlled. Keep a private
copy of version-2 Memory before downgrade; never promote confidential notes to
global scope merely to retain them in an older build.
