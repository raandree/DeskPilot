---
schema-version: 1
status: accepted
owner: software-engineer
last-verified: 2026-09-02
source: repository evidence
---

# 0007 — Localization: build-free ES-module catalogs, English source, German first

## Decisions

**Catalogs are ES modules, not JSON fetched at runtime.** `import { en } from
'./locales/en.js'` costs no request, no bundler, and no CDN — which is the
no-build constraint the whole SPA is held to. A missing catalog becomes a load
error the browser reports, rather than a silent 404 that renders raw keys.

**Flat, dotted keys.** `schedules.permissions.live`, not a nested tree. Key-set
equality between locales is then a set comparison a test can assert in both
directions, and an orphaned translation is as detectable as a missing one.

**English is both the source locale and the fallback.** A key missing from a
translation renders the English string and reports itself once through
`onMissing`; it never renders the raw key and never renders empty.

**Formatting delegates to Intl.** `Intl.PluralRules` chooses `one`/`other`, and
number, date, relative-time, currency and list formatting go through their Intl
counterparts. German needs the same two plural categories as English, but routing
through PluralRules means a language that needs `few`/`many` is a data change
rather than a code change.

**The language is a per-machine display preference in `localStorage`
(`ad_lang`), not a Setting on the Host Server.** It follows the precedent already
set by the theme (`ad_theme`) and the voice language (`ad_voicelang`): it shapes
no Turn, the Host Server gains nothing from knowing it, and keeping it client-
side means no server round-trip, no settings migration and no new wire field.
First run resolves it from `navigator.languages`, so `de-AT` lands on German.

**Server errors are localized by code, not by text.** The API keeps returning
`{ error: { code, message } }` unchanged; `errorText()` maps the stable code to a
localized string and falls back to the server's own message for a code that has
no key yet. The wire contract is untouched, which is what lets the client own the
language.

**Translations are written through DOM APIs.** `data-i18n` sets `textContent`,
`data-i18n-attr="title:key,aria-label:key"` sets attributes. Nothing here
produces or accepts HTML, so a conversation title containing `<img onerror=…>`
renders as a title. A test asserts `i18n.js` contains no `innerHTML` at all.

## Scope shipped

- The i18n runtime (`source/web/assets/i18n.js`) and complete `en` + `de`
  catalogs (~140 keys each).
- The **shell chrome**: sidebar, top bar, empty state, composer chips, sign-in
  card, Diagnostics modal headings and controls, and the whole scheduled-work
  surface — which is also the first surface where the localized strings are
  load-bearing at runtime rather than only in markup.
- The **safety copy** (`warn.*`): schedule-runs-unattended, schedule deletion,
  conversation deletion, discard-all-changes, update installation, and enabling
  Terminal. A test asserts each German warning differs from the English and is
  not materially shorter, because the failure mode for safety text is being
  trimmed to fit a control.
- A **Language** control in Settings → General with a *Match my system* option.

## Scope deliberately staged, and how it is prevented from rotting

The Settings drawer, the wizards (merge, clone, save), the Intercom panel and the
Customizations browser still carry English strings built inside `app.js`. A
static scan test counts every user-facing string in the shell markup that carries
no key and **fails if that number grows** — the baseline is 105, recorded on
2026-09-02. Extraction can therefore only ratchet downwards, and a new untagged
string in the shell fails the suite rather than quietly widening the gap.

This is an honest partial: the infrastructure, the resource discipline, the
formatting, the safety copy and the enforcement are complete; the long tail of
in-JavaScript strings is not. Claiming otherwise would have meant machine-
translating several hundred strings with no review path, which the prompt
explicitly rules out for safety text and which would be worse than a stated gap.

## Not translated, by rule

File paths, Agent names, Model ids, Tool names, JSON fields, route names,
persisted enum values (`queue`/`skip`, `safe`/`live`, outcome names), Model
output, and Project content. Intercom command tokens stay stable; only their
descriptions and responses would be localized.
