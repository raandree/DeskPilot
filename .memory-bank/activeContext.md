---
schema-version: 1
status: accepted
owner: shared
last-verified: 2026-09-08
source: terminal-theme regressions, browser screenshots, and full Sampler gate
---

# Active context

## Current focus

Terminal Amber and Terminal Green themes are implemented on
`ai/terminal-themes`. The user explicitly requested no commit yet. Nothing is
staged, committed, pushed, or published by this turn.

General Settings now separates Theme (DeskPilot, Terminal Amber, Terminal Green)
from Mode (System, Light, Dark). Theme uses browser-local `ad_color_theme`;
Mode preserves `ad_theme`. The top-bar switch changes only Mode. Dark terminal
variants use phosphor colours on near-black surfaces; light variants use dark
ink on near-white surfaces. Existing preferences retain DeskPilot by default.

The locally bundled 3270 font is from upstream v3.0.1, converted to WOFF2 with
`wawoff2` 2.0.1; the licence is included. Font research, hashes, browser support,
and return-to-default instructions are in [the theme guide](../docs/themes.md).
No runtime font CDN, Engine change, or Host Server Settings migration was added.

## Verification

- All 16 new native theme tests failed before the respective implementation and
  now pass; all 29 native JavaScript unit tests pass.
- Real-frontend Playwright checks with local fixture responses pass at 1440px
  and 390px for both terminal themes and both modes, System changes, reloads,
  English/German labels, bundled font loading, and absence of Host Server writes.
  Screenshot-discovered toolbar clipping and native-font inheritance gaps have
  regression guards. Screenshots were reviewed. Tested text/status pairs meet
  4.5:1 contrast; body text exceeds 10:1 in every terminal variant.
- Full default Sampler gate completed at 08:49:07 UTC: 2,551 passed, zero failed,
  18 skipped; 17 tasks with zero errors or warnings. All six changed bundled
  runtime assets match source hashes; the font is a valid 63,648-byte WOFF2.
- Changed code has no editor diagnostics. The theme guide is lint-clean;
  existing changelog heading/spacing warnings are untouched. Markdown renders,
  and `git diff --check` passes. Scoped self-review found no Blocker or Major;
  independent review remains off for this presentation-only change.

Full log: `TEMP/deskpilot-themes-full-1040a3adbe974e96a5f50a6c1e171052.log`.
Browser screenshots: `TEMP/deskpilot-themes-Mayscv`.

## Preview and next action

The built preview is running at <http://127.0.0.1:65515>, process 9196, using
`TEMP/deskpilot-theme-preview-5f395895aaec4f7aa70a6ea525bc30dd`. Its private launch
link was opened directly by DeskPilot, never printed. Root, current selector,
and WOFF2 content type were verified over real HTTP. Normal data and Telegram
Settings were not changed; no Model Turn or live Telegram delivery was tested.

Try Settings > General > Theme and Mode. Wait for the user's visual feedback or
explicit commit instruction. Do not use a Gallery update notice to replace the
development build. Terminal palettes require a browser supporting `light-dark()`.

## Retained release boundaries

FIND-011/FIND-012 are already closed; other findings remain in
[the assessment log](assessment-log.md). Earlier child V3 proof is source-bound
and does not prove this rebuilt Host Server. Child execution stays disabled;
the live profile was not rerun. Strict V2 still lacks its verified provider
counter, decision 0005 remains unapproved, and Terminal-only live acceptance
and clean-install Engine availability remain separate release work. This turn
did not change Engine worktrees, child execution, or approval authority.
