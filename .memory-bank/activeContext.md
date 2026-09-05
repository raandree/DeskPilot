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

**Three rounds, three FAILs.** Round one: 4 Blockers, 7 Majors, four of ten
design claims false. Round two, over the fixes: 2 Blockers, 3 Majors, every one
in round-one code. Round three, over those fixes: **2 Blockers, 4 Majors, 7
Minors, every Blocker again in the previous round's code.** All are now closed
and carry regression tests; decision 0003 has the detail.

The two that keep coming back are the same two, each time one component to the
left:

- **Where scope comes from.** The Model seeded it (round one). Then free-text
  parsing seeded it, so `README.md` and `install.sh` were authorised hosts
  (round two). Then the scheme match was unanchored, so `xhttps://evil.example`
  seeded it, and a userinfo address the classifier will *never* offer a card for
  granted permanent scope instead (round three). Scope now takes only complete
  `https://` URLs from the message, and only ones the classifier would raise a
  card for.
- **What counts as "not the Model's idea".** A bare path was exempt, on the
  claim it "carries no payload beyond the path itself" (round two). Then the site
  *root* was exempt, on the claim it "carries nothing" - it carries the host, and
  subdomains inherit scope, so `<200-bytes-of-context>.weather.example/` reached
  an attacker's DNS resolver with no card (round three). The root is now authored
  only for a host the user, the Project, or an approval named.

Also round three: sub-resources bypassed the peer-address check entirely, so an
`<img>` at a name resolving to `169.254.169.254` was fetched unchecked;
percent-encoding was a covert channel through provenance, closed by rebuilding
the address rather than comparing harder; and the turn-boundary close was dead a
second time - `Invoke-DpTurn` handed it a fresh hashtable - behind the same two
grep assertions round two had already named as worthless and left in place.

## Evidence

- Full Sampler gate: **2147 passed, 0 failed, 0 errors, 0 warnings.**
- Hostile-site proof: **25/25** against a real attacking page over HTTPS.
- Live workflow: **11/11** against the real site.
- The cross-parser invariant now runs over **23,040 generated cases** in four
  directions. The previous generator mutated only the first `.` of four fixed
  hosts and never produced a near-miss at the label boundary the property is
  about - it passed by construction.
- PSScriptAnalyzer on `source/`: nothing new in kind.

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

Three review rounds. Every round's Blockers were in the previous round's fixes,
and every one was defended by a sentence this repository had written about
itself and never tested.

What did not work: care, and re-reading. What worked: generating the test inputs
instead of enumerating them, and running the thing against a page that attacks
it. Round three also showed the failure mode of a *half*-generated test - a
generator that never produces the case the property is about passes by
construction and reads as proof.

The reviewer's diagnosis is the one to keep: this repository writes an
explanation, does not test it, and then treats the explanation as the evidence.
Recorded in `systemPatterns.md` as **grep for the caller before believing the
comment**, **a justification in a docstring is a hypothesis**, and **a fix ships
with a falsification attempt**.

