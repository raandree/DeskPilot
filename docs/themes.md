# Themes

Choose a **Theme** in **Settings > General**. **Mode** separately selects
**System**, **Light**, or **Dark**. The top-bar light/dark button changes Mode
without changing Theme.

| Theme | Dark mode | Light mode |
| --- | --- | --- |
| DeskPilot | Original deep teal | Original light palette |
| Terminal Amber | Amber text on near-black surfaces | Dark amber ink on near-white surfaces |
| Terminal Green | Green text on near-black surfaces | Dark green ink on near-white surfaces |

The terminal themes retain distinct error, success, and change colours. They
use no glow, scanline overlay, or flicker animation. Light mode is a readable
companion palette, not a historical CRT reproduction.

## Font research

Sources checked on 2026-09-08:

- **[3270](https://github.com/rbanffy/3270font), selected.** Its documented
  lineage runs through x3270 and Georgia Tech's 3270tool to a hand-copied IBM
  3270 terminal font. Its modern outline format fits the terminal reference
  without locking every control to a bitmap's native pixel size.
- **[IBM Plex Mono](https://github.com/IBM/plex), alternative.** IBM's
  contemporary open-source family is designed for UI use and distributed under
  the Open Font License. It is a suitable modern monospace choice, but the 3270
  lineage is a closer match for this feature. Plex is not bundled.
- **[Ultimate Oldschool PC Font Pack](https://int10h.org/oldschool-pc-fonts/readme/),
  alternative.** Its IBM PC text-mode recreations offer a stronger pixel-grid
  look. The author warns that pixel outlines scale best at their original pixel
  height or integer multiples. That is a poor fit for the range of control
  sizes and browser zoom levels here. The pack is not bundled.

3270 is used for terminal-theme text, code, and controls. Missing glyphs fall
back to locally available monospace fonts. The original DeskPilot typography is
unchanged. Use a current browser with CSS `light-dark()` support.

## Bundled font provenance

The font comes from the
[v3.0.1 release archive](https://github.com/rbanffy/3270font/releases/download/v3.0.1/3270_fonts_d916271.zip).
Its regular TrueType file was converted to WOFF2 with `wawoff2` version `2.0.1`,
without editing glyphs. The converter is a development utility, not a DeskPilot
runtime dependency. The font is served locally; no font CDN is contacted.

- [Bundled WOFF2](../source/web/assets/fonts/3270-Regular.woff2)
- [Unchanged upstream licence and glyph notices](../source/web/assets/fonts/3270-LICENSE.txt)

| Artifact | SHA-256 |
| --- | --- |
| Release archive | `623FB815B16D6C4940B5014A21C5474EF6CDDB02C325D03F153341B676B4CFFA` |
| Bundled WOFF2 | `17E7705FCDB614447D438998102AA16D3C83998EE40C691F612F0BCC8DEFFD75` |

## Preferences and verification

Theme is stored in the browser's `ad_color_theme` localStorage entry; Mode keeps
the existing `ad_theme` entry. Existing installations keep their Mode and use
DeskPilot unless a terminal theme is selected. Unknown values fall back to
DeskPilot and System. Choose **DeskPilot** to restore the original palette and
fonts. No Host Server Settings or Conversation data is migrated or changed.

Run the frontend unit suite with `node --test tests/Unit/*.test.mjs`. Run
`node tests/live/themes.mjs` with the existing DeskPilot Playwright runtime to
check the real frontend against local fixture data. It checks font loading,
English/German labels, persistence, System changes, toolbar bounds, and both
themes in both modes at desktop and mobile widths. No Engine call is made.
