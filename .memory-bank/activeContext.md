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

**Four rounds, four FAILs.** Round one: 4 Blockers, 7 Majors. Round two, over the
fixes: 2 Blockers, 3 Majors. Round three: 2 Blockers, 4 Majors, 7 Minors. Round
four: 2 Blockers, 4 Majors, 6 Minors. In every round after the first, the
Blockers were inside the previous round's fixes. All closed; decision 0003 has
the detail.

Four Blockers now share one shape: **a correct fact about component A written
down as a guarantee about component B.**

- Round two: "a bare path carries no payload beyond the path itself." The path is
  the payload.
- Round three: "the site root carries nothing." It carries the host, and
  subdomains inherit scope.
- Round four: percent-encoding "does not also have to be defended here, because
  the classifier rebuilds the address." True about unreserved encoding. The
  comparison operator two lines below was `-eq`, which in PowerShell is
  **case-insensitive** - so `/FoReCaSt/ToDaY` matched the page's
  `/forecast/today`, was certified as the site's own link, and reached the origin
  verbatim. About a bit per alphabetic character, and it works off the user's own
  typed URL, so no injected page is needed.

Round four's second Blocker had been there since before round one and three
rounds walked past it: the 8000-character bound on the user's message cuts
mid-token, so a pasted blob followed by the user's own address turned
`news.bbc.co.uk/weather` into `news.bbc.co` - a live registrable domain that then
seeded scope and inherited the site-root exemption. That exact string is the
example round two's docstring cites as the bug it had removed.

Also closed: the generated corpus asserted its properties on the URL the Model
typed rather than the one the tool sends; `fill` bound the page at the first
field and the submit but not in between; the sub-resource DNS check was
fail-open on a resolver assumption; and the 200-entry refusal ring turned a
blocked navigation into a reported success once a page filled it.

## Evidence

- Full Sampler gate: **2170 passed, 0 failed, 0 errors, 0 warnings.**
- Hostile-site proof: **25/25** against a real attacking page over HTTPS.
- Live workflow: **11/11** against the real site.
- The cross-parser property now runs on the **rebuilt** URL as well as the
  original. The reviewer attacked the rebuild over 76,581 generated cases and
  found zero host drift - it is the strongest control in the feature, and its
  strength was what made the case-insensitive comparison invisible.

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

Four review rounds. After the first, every round's Blockers were in the previous
round's fixes, and every one was defended by a sentence this repository had
written about itself and never tested.

What did not work: care, re-reading, and adding controls. Round three added the
strongest control in the feature - and then cited its strength, in a docstring,
as the reason not to look at the line below it. What worked, every time, was
someone trying to break the machinery the previous round had added. None of the
first three rounds did that; round four did, and that is where both Blockers
were.

The three standing rules are in `systemPatterns.md`: **grep for the caller before
believing the comment**, **a justification in a docstring is a hypothesis**, **a
fix ships with a falsification attempt**, and now **a guarantee about A is not a
guarantee about B**.

