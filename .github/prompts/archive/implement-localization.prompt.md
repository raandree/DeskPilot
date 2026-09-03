---
description: "Implement maintainable DeskPilot localization with German first"
agent: "software-engineer"
---

# Implement localization

## Why this feature is useful

DeskPilot removes technical barriers for knowledge workers, but an English-only
interface leaves another barrier in place. A structured localization system also
prevents translated safety text from drifting away from the controls it explains.

## Use case

A German-speaking legal professional selects Deutsch on first run. Navigation,
Permissions, approval warnings, errors, dates, numbers, and Intercom guidance use
German, while Project content, Agent answers, and technical identifiers remain
unchanged unless the user asks otherwise.

## Objective

Extract user-facing SPA and Host Server text into one build-free localization
system and ship English plus German. Preserve canonical internal identifiers,
wire contracts, and the repository's Ubiquitous Language.

## Required context

Read `specs/010-requirements.md`, `specs/030-api-contract.md`,
`specs/040-ui-design.md`, `.memory-bank/glossary.md`, and all user-facing text in
`source/web` and Host Server error/result paths. Inventory visible strings before
editing and classify them as UI chrome, safety text, dynamic message, server
error, technical identifier, or Model-generated content.

## Required behavior

- Add an explicit language Setting with automatic system-language detection on
  first run and a visible manual override.
- Ship complete `en` and `de` resources. English remains the source locale and
  fallback for a missing key.
- Keep resources static and bundled; add no runtime CDN or build requirement.
- Support interpolation, plural forms, dates, times, relative times, numbers,
  currencies, and list formatting through browser-standard internationalization
  APIs where available.
- Localize Host Server errors through stable error codes plus client-side text.
  Keep diagnostic detail separate and safe.
- Localize Intercom commands only if backward-compatible aliases are retained;
  otherwise localize descriptions and responses while command tokens stay
  stable.
- Never translate file paths, Agent names, Model ids, Tool names, JSON fields,
  route names, or persisted enum values.
- Preserve the user's selected language across launches.
- Make every destructive-action warning and Permission explanation complete in
  both locales before the feature ships.

## Translation quality boundaries

- Create one glossary mapping DeskPilot product terms to approved German terms.
  Do not translate the Engine or Model in ways that collapse their distinction.
- Keep security meaning equivalent rather than shortening warnings to fit.
- Design controls for text expansion; do not solve overflow by shrinking all
  text or truncating safety copy.
- Add translator notes for ambiguous placeholders and product-specific terms.
- Prevent HTML injection by interpolating text through DOM-safe APIs, never
  concatenated `innerHTML`.

## Test-first proof

Add failing deterministic checks before broad string extraction. Cover at least:

- Every locale has the same keys, valid placeholders, and no orphaned entries.
- Missing keys fall back to English and emit a development diagnostic.
- Dynamic values with HTML-like content render as text.
- German plural, date, number, currency, and list formatting.
- Language persistence and first-run detection.
- Error codes map to localized text without changing API contracts.
- Long German labels fit supported desktop and mobile viewports without overlap.
- A static scan reports remaining unclassified user-facing strings.

Perform a human review of German Permission, approval, deletion, update, and
Intercom warnings. Machine translation alone is insufficient for safety text.

## Definition of done

- English and German cover all normal, empty, loading, warning, and error states.
- Update UI design, user documentation, accessibility labels, and roadmap.
- Run locale consistency checks, JavaScript syntax checking, focused Pester tests,
  viewport screenshots, and the full Sampler build and test gate.
- Update `CHANGELOG.md` and routed Memory Bank records.
- Commit on a focused topic branch. Do not push.

## Non-goals

- Translating Model output or Project content automatically.
- Adding languages without an owner and review path.
- Translating technical identifiers or persisted wire values.
- Introducing a frontend build pipeline solely for localization.