---
schema-version: 1
status: accepted
owner: shared
last-verified: 2026-09-03
source: repository evidence
---

# Active Context

## Current focus

**Contained browser automation is complete and has survived an independent
security review.** Every open item from the prompt's Definition of Done is done:
the approval card, the Settings surface, Diagnostics orphan cleanup and
uninstall, the hostile-site suite, the live workflow, UI screenshots, specs
030/040/060, `docs/browser-automation.md`, and the review itself.

## What the review changed

It returned **FAIL — 4 Blockers, 7 Majors**, and found **four of ten design
claims false as stated**. All are fixed with regression tests; decision 0003
carries the detail. The four that mattered most:

- **The Model seeded its own scope**, giving every Turn one free unapproved
  navigation to any host — a complete exfiltration channel. Scope now comes from
  the user's own message, and a Model-composed query even on an in-scope host is
  approved like a departure.
- **The two enforcement points disagreed on 26 of 80 URLs**, because
  `System.Uri` performs no IDNA mapping and Chromium does. The card could name a
  host the browser would never contact. Both sides now compare on `IdnHost`, and
  the corpus asserts equality *and* the never-more-permissive invariant that had
  been claimed in a header comment and never tested.
- **Stop did not close the browser.** `Close-DpBrowserSession` had one caller:
  the start of the *next* Turn. Its own docstring said otherwise.
- **`DESKPILOT_BROWSER_ROOT` replaced the entire policy with arbitrary Node
  code**, silently, while the two strictly weaker test hooks beside it had a
  guard test, a warning and a ready-line flag.

Every Blocker was a claim this repository had written about itself, three of
them in docstrings. None had a test. All four do now.

## Evidence

- Full Sampler gate: **2098 passed, 0 failed, 0 errors, 0 warnings.**
- Hostile-site proof against a real attacking page over HTTPS: **24/24.**
- Live Osorno workflow against the real site: **11/11.**
- UI screenshots at 1440, 820, 720, 700, 620 and 400 px, rendering the real card
  builder rather than a hand-written copy of its markup.
- PSScriptAnalyzer on `source/`: 48 findings, both non-house-style ones
  pre-existing and in other files.

Defects found by running things rather than by reading them: the pop-up handler
was registered before `state.page` existed, so it closed the page `newPage()`
had just created and every navigation failed; `, $array.ToArray()` on an empty
list produced a phantom element that made the proof report an orphan that did
not exist; and `Should -Invoke -Times 0` without `-Exactly` asserts nothing, so
every "never contacted anything" test was vacuous.

## Deliberate gaps, not oversights

- **`click_link` is not gated.** A link can have a side effect on a badly-built
  site. Bounded by scope, unchanged since the read-only slice, and the one action
  with a plausible external effect that raises no card.
- **Minors m-1, m-2, m-3, m-9, m-10, m-11, m-12 from the review are open.** The
  substantive ones are locator ambiguity when two elements match the Model's
  substring (m-1), and off-origin passive sub-resources remaining allowed after
  an approved fill has put Model-derived data into the DOM (m-2).
- **The test hooks remain a residual risk**, now surfaced through the runtime,
  Diagnostics and a warning. `DESKPILOT_BROWSER_TEST_ARGS` accepts arbitrary
  Chromium arguments including `--user-data-dir`, so anyone able to set a
  user-scoped environment variable can point the "throwaway profile" at a real
  one. Asset hashing against the manifest would close it properly.

## Inherited approval work

Unchanged: per-call approval is enforced only against the locally staged
`output/RequiredModules/ShellPilot/0.4.1`. The installed and newest published
build is `0.4.0`, and `RequiredModules.psd1` pins `'latest'`, so the capability
probe fails closed on any other machine. `perCallApproval` still ships off.

Isolated Tool execution (decision 0001) remains blocked on its own
prerequisites; scoping *this* feature's isolation to the browser deliberately
does not touch that.

## The lesson this session keeps re-teaching

It stopped being a lesson about inherited claims and became one about claims
made *in the same session*. Adding write actions falsified "no action has an
external effect" in four documents written hours earlier. The security review
then falsified four more, all of them written down by this repository about
itself, none of them tested. The pattern is now recorded in `systemPatterns.md`
as **grep for the caller before believing the comment**.

