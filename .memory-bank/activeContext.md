---
schema-version: 1
status: accepted
owner: shared
last-verified: 2026-09-03
source: repository evidence
---

# Active Context

## Current focus

**Contained browser automation shipped as a read-only first slice.** The
prerequisite gate in decision 0003 had been recorded as blocked twice. It opened
after the isolation requirement was scoped to the browser's own boundary — a
supervised child process and a throwaway profile, which needs no Docker — and
after the user supplied the workflow, domains, data and action set.

The authorised workflow is a weather lookup: follow links through
`weathercity.com` to Osorno. `browser_page` offers `open`, `click_link`,
`read_page` and `screenshot`, and nothing with an external effect, behind a
separate `browserAutomation` Permission that ships off.

## Evidence

- Red first: 65 policy tests failed on missing functions, then passed.
- Browser suite: **270 tests**, including a 63-case corpus run through *both*
  the PowerShell classifier and `policy.mjs`, asserting identical verdicts plus
  a one-way "never more permissive" invariant.
- Protocol suite runs against a stand-in supervisor, so framing, correlation,
  deadline handling and process teardown are proved without a browser installed.
- Full Sampler gate: **1932 passed, 0 failed, 0 errors, 0 warnings.**
- PSScriptAnalyzer on `source/` went 49 → 47 findings; both remaining are
  pre-existing and in other files.

One real bug was caught by the analyzer rather than by a test: the first
`Invoke-DpBrowserProcess` collected output through `Register-ObjectEvent -Action`
scriptblocks, which cannot reach the enclosing `$buffer`. Rewritten with
concurrent async stream reads. A Pester weakness was caught the same way —
`Should -Invoke -Times 0` without `-Exactly` asserts nothing at all, so every
"never contacted anything" assertion was vacuous until `-Exactly` was added.
They still passed afterwards.

## Next step

**The live proof needs the user's consent to install a browser engine.** The
hostile-site harness (`tests/live/Invoke-DpBrowserHostileTest.ps1`) and the
attacking site (`tests/live/hostile-site.mjs`) are written and currently report
honestly that the runtime is absent. Running them means downloading Playwright
1.63.0 and Chromium into the data directory, which is exactly the consent gate
this feature was built around, so it is the user's call rather than a step to
take on their behalf.

Until then the boundary is proved against a URL corpus and a stand-in
supervisor, not against a real hostile page. That distinction is the whole point
of this repository's recurring lesson and should not be glossed.

## Deliberate gaps, not oversights

- **No Settings UI for `browserDomains`.** The field is accepted and validated
  by the API and honoured per Turn; there is no control for it yet.
- **The approval card has no browser-specific rendering.** It carries `url` and
  `host` in the summary and a navigation-specific risk line, but the SPA still
  draws it with the terminal card's layout.
- **No screenshots at supported viewports.** Requires the runtime.
- **No independent agent-security review yet.** Recommended; the change touches
  a security boundary and an outbound path.

## Inherited approval work

Unchanged and still true: per-call approval is enforced only against the locally
staged `output/RequiredModules/ShellPilot/0.4.1`. The installed and newest
published build is `0.4.0`, and `RequiredModules.psd1` pins `'latest'`, so the
capability probe fails closed on any other machine. `perCallApproval` still
ships off.

Isolated Tool execution (decision 0001) remains blocked on its own
prerequisites; scoping *this* feature's isolation to the browser deliberately
does not touch that, and is not a precedent for calling process separation
"isolation" for terminal commands.

## The lesson this session keeps re-teaching

Two more inherited claims were measured and corrected today. `systemPatterns.md`
still asserted that `-DisableTerminal` gated dispatch in 0.4.0 — the exact claim
the anti-patterns section below it already records as false — and
`specs/100-feature-selection.md` still said Playwright and interactive page
control were absent. A record that contradicts itself in two places is a record
nobody re-read. Both are corrected.
