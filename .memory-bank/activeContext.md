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

**Five rounds, five FAILs.** After the first, every round's Blockers were inside
the previous round's fixes. All closed; decision 0003 has the detail.

Five Blockers now share one shape: **a correct fact about component A written
down as a guarantee about component B.**

- Round two: "a bare path carries no payload beyond the path itself." The path is
  the payload.
- Round three: "the site root carries nothing." It carries the host, and
  subdomains inherit scope.
- Round four: percent-encoding "does not need defending here, because the
  classifier rebuilds the address." True of unreserved encoding; the comparison
  operator two lines below was `-eq`, which is case-insensitive.
- Round five: "a URL in the user's message was named by the user." True of the
  outer URL, and round four wrote it down as a guarantee about every substring -
  so an OAuth link's `?redirect_uri=https://attacker.test/cb` seeded
  `attacker.test` and its whole subtree, no card. That splitter was added for a
  **cosmetic** Minor whose unfixed behaviour was already fail-safe.

Round five's second Blocker was the test written to answer round four's: the
rebuilt-URL check only asked whether JS agreed with whatever PowerShell produced,
so it passed with the rebuild deleted outright.

Also closed: the DNS guard's budget reset on `framenavigated`, which
`history.pushState` fires, so a page could restore it 500 times without a network
request; the budget counted resolver calls rather than hostnames, so one host
spent all of it and then refused the page's own images; a transient SERVFAIL was
cached as a positive "resolved to an internal address"; and the refusal counter's
third hole let a sub-frame refusal deny every click and choose the text of the
refusal message.

## The change that matters more than any single fix

The reviewer measured that **53 of 54** ways to disable a supervisor control left
the suite green, because the assertions read `supervisor.mjs` as text and it
cannot be imported without Playwright.

That is now closed on both halves of the boundary. **28 controls** are covered by
two mutation matrices that disable each one in turn and fail the suite if nothing
notices:

- `tests/Unit/fixtures/mutate-guards.mjs` - 16 controls in
  `source/browser/guards.mjs`, which takes its resolver and clock as arguments so
  no browser is needed. The host guard, the refusal log, the write binding and the
  download-name sanitiser all moved there.
- `tests/Unit/fixtures/Invoke-DpBrowserMutation.ps1` - 12 controls in
  `source/Private`, each mutated in a copy of the tree with only the tests that
  claim to cover it run.

Both found toothless checks on their first run. The PowerShell matrix found the
host comparison in `Test-DpBrowserUrlFromPage` had **no test at all** - removing
it let a link published on `weather.example` author the same path on
`payload.weather.example`, which is B3-1's channel wearing the page's own path.
Found by measurement, not by a sixth review round.

The test file now states which of its assertions are behavioural-and-proven,
behavioural, or wiring-only, so a `Should -Match` can no longer read as coverage.

## Evidence

- Full Sampler gate: **2211 passed, 0 failed, 0 errors, 0 warnings.**
- Hostile-site proof: **25/25** against a real attacking page over HTTPS.
- Live workflow: **11/11** against the real site.
- Mutation coverage: **28/28** disabling mutations detected.

## The exit criterion

Written into decision 0003, because without one this runs forever. A round passes
when no Blocker or Major is open, every control has a mutation entry, every
remaining source-text assertion is labelled as wiring, and **the diff adds no new
control** - a round that only adds machinery has not been reviewed.

One product decision is recorded as open rather than settled by default: whether
the write capabilities ship in the first release at all. They own roughly half
the supervisor and a matching share of the findings, and read-only would cost
nothing for the workflow this feature was commissioned for.

Defects found by running rather than reading, across three rounds: the pop-up
handler closed the page `newPage()` created; `, $array.ToArray()` produced a
phantom element; `Should -Invoke -Times 0` without `-Exactly` asserts nothing; a
blocked navigation left an error-page transition in flight that interrupted the
next one; and the navigation stamp raced its own navigation.

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

Five review rounds. After the first, every round's Blockers were in the previous
round's fixes, and every one was defended by a sentence this repository had
written about itself and never tested.

What did not work: care, re-reading, and adding controls. Round four added
fifteen controls and eleven falsification attempts, and the attempts covered the
two files where nothing broke while ten fresh source-text greps covered the six
supervisor controls where four things did.

What worked, every time, was someone trying to break the machinery the previous
round added. Rounds one to three never did; rounds four and five did, and that is
where every Blocker was.

Round five's answer was to stop adding and start exposing: the supervisor guards
moved to a module a test can execute, and the suite now fails if disabling a
control goes unnoticed. That is the first artifact in this feature that measures
whether its own tests are worth anything.

