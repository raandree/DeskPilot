---
schema-version: 1
status: accepted
owner: shared
last-verified: 2026-09-03
source: repository evidence
---

# Active Context

## Current focus

**Contained browser automation, now with per-Project write capabilities.**
The read-only slice shipped first (decision 0003) after the prerequisite gate
opened; write actions were added on request immediately afterwards.

Reading — `open`, `click_link`, `read_page`, `screenshot` — is always available
and has no external effect. Writing — `fill_form`, `click_button`,
`upload_file`, `download_file` — exists only where a Project grants the matching
capability from `browserActions` (`fill`, `submit`, `upload`, `download`), all
absent by default.

**This materially changed the security posture and the record says so.** The
read-only surface broke the agency leg of the trifecta by architecture. Write
capabilities give part of it back, so approval stops being a backstop and
becomes the only thing between an injected page and an irreversible action.
That is why there is no safe-list, why the card carries the values, and why the
fingerprint covers them.

## Evidence

- Browser suite: **333 tests.** Includes an 83-case shared corpus run through
  both the PowerShell classifier and `policy.mjs` with a one-way "never more
  permissive" invariant, and the credential-field cases run through Node because
  only the live DOM check can decide them.
- Full Sampler gate: **1995 passed, 0 failed, 0 errors, 0 warnings.**
- PSScriptAnalyzer on `source/` steady at 47 findings; both non-house-style ones
  are pre-existing and in other files.

Two defects were caught by tooling rather than by reasoning, both worth keeping:
the first `Invoke-DpBrowserProcess` collected output through
`Register-ObjectEvent -Action` scriptblocks, which cannot reach the enclosing
`$buffer`; and `Should -Invoke -Times 0` without `-Exactly` asserts nothing, so
every "never contacted anything" assertion was vacuous until it was added.

## Next step

**The live proof still needs consent to install a browser engine.** The
hostile-site harness (`tests/live/Invoke-DpBrowserHostileTest.ps1`) and the
attacking site (`tests/live/hostile-site.mjs`) report honestly that the runtime
is absent. Running them means downloading Playwright 1.63.0 and Chromium into
the data directory, which is the consent gate this feature was built around.

The hostile site does **not** yet attack the write surface. It should grow a
form whose fields are relabelled after approval, a password box wearing an
innocuous name, a file input the page tries to point at something outside the
Project, and a download with a traversal filename. Until then the write path is
proved by unit tests and a stand-in supervisor, not by a real hostile page.

## Deliberate gaps, not oversights

- **No Settings UI for `browserDomains` or `browserActions`.** Both are accepted
  and validated by the API and honoured per Turn; neither has a control yet, so
  granting a write capability currently means editing settings by hand.
- **`click_link` is not gated.** A link can have a side effect on a badly-built
  site. It is bounded by scope and unchanged from the read-only slice, but it is
  the one action with a plausible external effect that raises no card.
- **The approval card has no browser-specific rendering.** It carries `url`,
  `host`, `action`, `control`, `filePath` and `fields`, but the SPA still draws
  it with the terminal card's layout — so the values that make a write approval
  meaningful are in the payload and not yet on screen. This is the largest gap.
- **No screenshots at supported viewports**, and **no independent
  agent-security review**. The second is now more strongly recommended than it
  was: the change touches an outbound path that can submit, upload and delete.

## Inherited approval work

Unchanged: per-call approval is enforced only against the locally staged
`output/RequiredModules/ShellPilot/0.4.1`. The installed and newest published
build is `0.4.0`, and `RequiredModules.psd1` pins `'latest'`, so the capability
probe fails closed on any other machine. `perCallApproval` still ships off.

Isolated Tool execution (decision 0001) remains blocked on its own
prerequisites; scoping *this* feature's isolation to the browser deliberately
does not touch that.

## The lesson this session keeps re-teaching

Two more inherited claims were measured and corrected. `systemPatterns.md` still
asserted that `-DisableTerminal` gated dispatch in 0.4.0 — the exact claim the
anti-patterns section below it already records as false — and
`specs/100-feature-selection.md` still said Playwright and interactive page
control were absent. A record that contradicts itself in two places is a record
nobody re-read.

The same trap reappeared within this feature: adding write actions made "the
Tool surface contains no action with an external effect" false in four separate
documents that had just been written. Every one was corrected in the same edit
rather than left for the next reader to trip over.

