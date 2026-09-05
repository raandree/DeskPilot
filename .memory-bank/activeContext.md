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

**Two rounds, both FAIL.** Round one: 4 Blockers, 7 Majors, four of ten design
claims false. Round two, over the fixes: **2 more Blockers and 3 Majors, every
one of them in code written to fix round one.** All are now closed and carry
regression tests; decision 0003 has the detail.

Round one's four:

- **The Model seeded its own scope**, giving every Turn one free unapproved
  navigation to any host.
- **The two enforcement points disagreed on 26 of 80 URLs** (`System.Uri` does no
  IDNA mapping, Chromium does), so the card could name a host the browser would
  never contact.
- **Stop did not close the browser.** `Close-DpBrowserSession` had one caller:
  the start of the *next* Turn.
- **`DESKPILOT_BROWSER_ROOT` replaced the entire policy with arbitrary Node
  code**, silently.

Round two found that two of those fixes had moved the problem rather than
removed it:

- **Scope came from free text**, so `README.md`, `install.sh` and `main.py`
  became authorised hosts — all live TLDs — text the user *pasted* authorised
  whatever it mentioned, and a trailing slash backtracked a label so
  `news.bbc.co.uk/weather` authorised `news.bbc.co`. Now only complete `https://`
  URLs the user wrote.
- **Path and fragment were unapproved egress.** `Test-DpBrowserUrlFromPage` waved
  through anything with no query, on a docstring claim that "a bare path carries
  no payload beyond the path itself". The path *is* the payload. The fragment was
  excluded as "never leaves the browser" — `location.hash` reads it in full.
- **The Stop fix was dead code that threw every time.** It opened a pipeline on
  the Engine Runspace, which is mid-`Invoke-Shp` at exactly that moment, and a
  `catch` swallowed it. The test asserted the function's own name appeared in the
  route. The session state now lives on the Host Server side and is injected by
  reference, so closing needs no pipeline.

## Evidence

- Full Sampler gate: **2105 passed, 0 failed, 0 errors, 0 warnings.**
- Hostile-site proof: **25/25**, three consecutive runs, against a real attacking
  page over HTTPS.
- Live Osorno workflow: **11/11** against the real site.
- The parser invariant is now asserted over ~1,700 *generated* mutations rather
  than a curated corpus — and it caught a class on its first run.
- PSScriptAnalyzer on `source/`: 48 findings, both non-house-style ones
  pre-existing and in other files.

Defects found by running rather than reading, across both rounds: the pop-up
handler closed the page `newPage()` had just created; `, $array.ToArray()` on an
empty list produced a phantom element; `Should -Invoke -Times 0` without
`-Exactly` asserts nothing; a blocked navigation left an error-page transition
in flight that interrupted the *next* one; and the navigation stamp raced the
navigation that produced it.

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

Two review rounds produced six false claims, all written by this repository
about itself, none tested. Round two's Blockers were *all* in code written to
fix round one's.

What did not work: care, and re-reading. What worked: generating the test inputs
instead of enumerating them, and running the thing against a page that attacks
it. Every Blocker in both rounds was found by measurement, and the corrected
parser invariant caught a fresh divergence class on its first generated run.

Recorded in `systemPatterns.md` as **grep for the caller before believing the
comment**, and now also as **a justification in a docstring is a hypothesis**.

