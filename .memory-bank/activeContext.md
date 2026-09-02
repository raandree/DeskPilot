---
schema-version: 1
status: accepted
owner: shared
last-verified: 2026-08-13
source: repository evidence
---

# Active Context

## Current focus

**Microsoft Scout is now included in the competitive decision set
(2026-09-02).** Official Microsoft Learn documentation establishes Scout as a
Frontier-preview Windows/macOS desktop Autopilot spanning files, shell, browser,
Microsoft 365, per-action approval, heartbeat, scheduled and condition-triggered
automations, specialized parallel sub-agents, Memory, Skills, and enterprise
policy. Microsoft's engineering account adds an untrusted container mediated by
zero-trust identity, token, Tool, Model, policy, and network boundaries. The
user-supplied hands-on transcript is retained as secondary corroboration, not as
the source for unsupported claims. Scout reinforces the existing order:
per-call approval first, then diagnostics, scheduled work, packaging and
localization, and optional isolation. Two genuinely separate candidates now
have Prompt Files: read-only Microsoft 365 work integration and confined local
condition-triggered automation. Neither is a roadmap commitment.

**Ten competitive-gap Prompt Files are ready for selection (2026-09-02).**
The five ranked gaps are expanded into independent implementation briefs, with
packaging and localization split because their dependencies and rollback paths
differ; the two original later bets and two Scout-derived candidates are also
included. Every Prompt File opens with
why the feature matters and a concrete DeskPilot use case, then pins required
context, behavior, safety boundaries, test-first proof, Definition of Done, and
non-goals. Per-call approval remains the recommended first choice. Isolated Tool
execution requires approval; parallel Agents require approval plus isolation;
Playwright browser automation requires both plus one named workflow and a broken
lethal-trifecta path. DeskPilot currently has browser-based UI and the Engine's
`fetch_url` Browsing Tool, but no interactive page control or Playwright
dependency. The browser prompt now explicitly chooses Playwright and covers its
Node.js, managed-browser, offline, update, repair, and uninstall lifecycle. The
Prompt Files are decision artifacts, not roadmap commitments.

**Competitive harness research completed (2026-09-02).** Spec 100 now compares
DeskPilot with Hermes Agent, Hermes One, OpenHands, Cline, Roo Code, Continue,
Goose, OpenCode, and Aider using primary sources and explicit evidence states.
The result is decision input, not a roadmap commitment. The strongest candidate
is per-call approval, followed by diagnostics, scheduled work, packaging and
localization, and optional isolated Tool execution. Parallel Agents and browser
automation remain later bets because both amplify the current full-user-
privilege execution model. Multi-provider support remains a deliberate non-goal
while DeskPilot is Copilot-native. All external links passed MarkdownLinkCheck;
no runtime code changed.

**Previous focus — Intercom group access remains uncommitted.**

**A Telegram group can reach Intercom alongside the operator's own chat
(2026-09-02, uncommitted on `main`).** Reported from a Status panel reading
`Received 15 · accepted 3 · rejected 12`, with twelve
`Message from chat '-1004455397827' is not allow-listed.` lines: the bot had
been added to a group and everything sent there was counted and dropped.

Spec 110 named **No multi-user. Exactly one allow-listed chat.** a *permanent*
non-goal, so the scope and the sender-trust model went to the operator rather
than being assumed. They chose **additional** (both chats accepted, not a
replacement) and **anyone in the group**. The non-goal is now *No per-sender
identity* — Intercom still carries exactly one authority; what changed is who
may exercise it — and the widening is recorded as accepted risk **A3**.

Five decisions. **(1) Two switches, not a nullable id.** `allowGroupChat`
(`$false`) gates `groupChatId` (`$null`), and either alone accepts nothing. A
group hands the operator's whole authority to a membership Telegram controls, so
allowing one must be a visible act rather than a field that starts working when
it stops being empty; the consequence is stated where it is enabled and repeated
on every `/status` check-in. **(2) The group field refuses a positive id**
(`^-\d{1,20}$`) and one equal to `chatId`, cross-checked *after* the key loop
because a patch may carry both keys and a hashtable has no order — otherwise a
second private chat could be allow-listed through the group door, where the
shared-control warning does not apply. **(3) Answer where you were asked.**
`Intercom.ReplyChatId` is the ambient target, `Send-DpIntercomMessage` stamps it
onto every queued record and the pump sends to `$record.chatId`, so all 109 call
sites are untouched. The pump sets it around each dispatch and restores it in a
`finally`; anything that outlives one tick carries its own copy — `QueuedChatId`
for a queued prompt, `Download.chatId` for the two-call attachment fetch,
`PendingQuestion.chatId` for a forwarded question. The live status message is
forced to the operator's chat, because there is one of it and one
`StatusMessageId`. **(4) The answer nonce is chat-scoped now.** Telegram numbers
messages per chat, so once two chats are allow-listed an unrelated reply in one
can carry the same `message_id` as the question pending in the other;
`PendingQuestionChatId` makes a reply an answer only in the chat the question
went to. Widening an allow-list silently invalidates every identifier that was
unique only because the list had one entry. **(5) Turning the group off drops
what it left behind** — a pending question or queued prompt bound to the old
group is discarded in the PUT handler rather than delivered to a chat that is no
longer trusted.

The new addressing fields are read through `Get-DpPropertyValue`: an absent
value has a defined meaning (the operator's chat), and `Send-DpIntercomMessage`
sits on the path that reports a finished job, where a StrictMode missing-key
throw loses the result — the same failure the codebase already learned once in
`Invoke-DpIntercomTurn`.

Also surfaced what Telegram will not: a bot in a group sees only `/commands`,
replies to itself and @mentions until **Group Privacy** is turned off in
BotFather *and the bot is removed and re-added*. That is a Telegram-side setting
DeskPilot cannot read, and its symptom is indistinguishable from DeskPilot
ignoring the operator, so it is stated in the Settings panel and the
getting-started guide.

Verified: AST parse clean across `source/Private`, `node --check` clean on
`app.js`, PSScriptAnalyzer no new findings, full Unit suite **1352/1352**, 0
failed — including 13 new tests covering the default-off gate, both chats being
accepted at once, the cross-chat nonce, the two id validations, and the three
routing cases.

**Follow-up — "the agent hangs when sending prompts via the group"
(2026-09-02).** The log said otherwise: `Received 1 · accepted 1 · rejected 0`,
a question forwarded at 3:21:30 as a numbered list of six, and a stall warning at
3:26:30. The Turn was not hung, it was **parked on an Ask-User question** — and
the watchdog told the operator *"it may be running something long, or it may be
stuck. Send /stop to end it"*. DeskPilot knew exactly why nothing was happening,
and the advice it gave would have killed a job that was only waiting for a reply.
That message *is* the reported hang. The watchdog now branches: a Turn with a
`PendingQuestion` gets a reminder that names the wait and points at the question
message, and `Submit-DpIntercomAnswer` stamps `LastActivityUtc` and clears
`StallNotified`, so answering re-arms the one-shot warning and a genuine stall
afterwards is still reported rather than swallowed by the reminder.

Second defect, visible in the same log: the Turn started with
`@Janis1bot this is the prompt for a new app: ...`. Under Telegram's group
privacy an @mention is **the only way a plain instruction reaches the bot**, so
it is addressing rather than content — exactly the reason `/command@BotName`
already loses its suffix — yet it reached the agent as the first words of the
work and became the Conversation title, which is derived from them. It is now
stripped on a word boundary (`@bot2` is not `@bot`), and a message that is only a
mention is ignored rather than run as an empty prompt. The name comes from one
non-blocking `getMe` started on the enable transition and reaped like every other
Telegram call; the test route, which already called `getMe` and threw the
username away, now caches it too. A failed lookup costs only the noise.

Verified: full Sampler `build, test` — **1370 tests, 0 failures, 0 errors**, 16
tasks, 0 warnings. The watchdog pair is not vacuous: the sibling case asserts a
genuinely quiet Turn still produces `stalled`, so the branch is provably reached.

**Security review (2026-09-02) — verdict CONDITIONAL, seven findings open.**
`ee0bdd7` is safe to hold on the branch because the feature is default-off, but
**`allowGroupChat` must not be switched on** until the two High findings are
closed. Full evidence and CVSS in `.memory-bank/assessment-log.md`; the work
order is `.github/prompts/fix-intercom-group-findings.prompt.md`.

The two that block: **`/undo` and `/delete` never call `Test-DpIntercomProject`**,
so any group member can rewrite files on disk and destroy Conversations in any
Project; and **the per-Project `intercom` flag cannot distinguish "me" from "the
group"**, so ticking the box retroactively extends every opted-in Project,
`git push` included, with no re-confirmation. Both were latent and harmless while
the only caller was the operator — this commit is exactly what invalidates that
assumption, which is the general lesson: *widening an allow-list silently
re-scopes every gate that was calibrated for one caller.*

Also open: the audit log records no sender for an accepted command (the data is
computed and thrown away); work bound to a just-de-authorised chat is still
delivered there; and `Send-DpIntercomMessage` does not re-validate its target, so
the "never answer a caller you just rejected" invariant now rests on one early
`return`. The last two share one structural fix — re-validate the resolved target
against the live allow-list at enqueue time — which is preferable to enumerating
every path that must clear stale routing state, since failing to enumerate one
*is* the bug.

Fixed during the review: `CHANGELOG.md` had `### Fixed` before `### Added` and a
duplicate `### Added` under one release heading, against Keep a Changelog order.

**Follow-up — a group Turn answered privately (2026-09-02).** Reported from two
screenshots: the acknowledgement in the group at 5:44, the agent's question in
the private bot chat at 5:49. That split *is* the diagnosis — the ack is sent
during dispatch, the question minutes later inside the Turn. The pump is
**re-entrant** (`Update-DpIntercomState` → `Invoke-DpIntercomTurn` →
`Invoke-DpTurn` → `Invoke-DpPendingRequest` → `Update-DpIntercomState`), and the
nested tick's `finally { $intercom.ReplyChatId = $null }` in the download block
ran on every non-pairing tick, wiping the target the outer Turn owned.

It was not only misrouting: `PendingQuestion.chatId` comes from the same ambient
value, so the nonce was recorded against the private chat and a reply in the group
would have been read as a new prompt — the Turn would have stayed blocked, which
is the "hang" all over again by a different route.

Fixed by capturing the caller's value and restoring *that* at all three override
sites; the disable transition still nulls, correctly, because nothing is running.
Red-first was proved, not assumed: the committed pump was swapped back in under a
`try`/`finally`, the two new tests ran **0 passed / 2 failed**, and the fixed file
was restored and re-counted. Gate **1372/1372**.

No CHANGELOG entry — the `[Unreleased]` Added entry already promises "It replies
wherever it was asked", which was false when written and is now true.

**Follow-up — questions are tappable now (2026-09-02).** The operator asked for a
"more comfortable" question format and believed it had regressed. It had not:
`Initialize-DpQuestionnaireTool` has told the model *"Use ONE call to bundle all
related questions; do not ask them one at a time"* since 2026-08-05, while
`Send-DpIntercomQuestion` rendered a keyboard only for `questions.Count -eq 1`
since 2026-08-09 — byte-identical ever since. **DeskPilot instructed the model
never to produce the only shape its own phone UI could render as buttons.**

Fixed by making the renderer match the contract: `Send-DpIntercomQuestionStep`
sends one question at a time with its options as buttons and a per-step nonce,
`Move-DpIntercomInterview` advances or submits, and
`ConvertTo-DpQuestionnaireAnswer` serializes to the browser wizard's own wire
format so the bridge is still called exactly once. Multi-select toggles and closes
on **Done**, with feedback as a toast on the tap acknowledgement. A typed reply is
mapped onto the options first, so "2" and "1,3" still work.

**Two existing tests were vacuous** and were rewritten: the mock recorded
`HasKeyboard = $PSBoundParameters.ContainsKey('Keyboard')`, which is always
`$false` inside a Pester mock when the caller splats. `Should -BeFalse` had never
tested anything, and kept passing after the behaviour was reversed. Assert on the
parameter's value, never on `$PSBoundParameters`.

Gate: **1384 tests, 0 failures**; PSScriptAnalyzer clean on every changed
production file.

**Follow-up — several groups, not one (2026-09-02).** `intercom.groupChatId`
became `intercom.groupChatIds`, an array capped at ten. The Settings box takes a
comma-separated list; each id is still validated as negative, de-duplicated, and
refused when it equals `chatId`. The retired singular key is still read so an
existing `settings.json` migrates on load — verified against the operator's real
file rather than a fixture. De-authorisation is now a set difference, so removing
one group of several drops only the work bound to that one.

**All seven review findings closed (2026-09-02).** Verdict moves **CONDITIONAL →
CLEARED for the branch**: `allowGroupChat` may now be switched on. It was not
switched on during this work, and nothing was pushed. Per-finding evidence is in
`.memory-bank/assessment-log.md` under the same entry.

**FIND-002 was the design decision, and the operator chose both halves.** A
per-Project **`intercomGroup`** flag, default off *even for a Project the
operator's own phone already drives*, checked in `Test-DpIntercomProject` through
a new `-OriginChatId`. Plus a server-side disclosure: `PUT /api/intercom` refuses
to switch `allowGroupChat` on with **409 `confirm_group_projects`** and the names
of the Projects it would cover, until the same request carries
`confirmGroupProjects: true`. The flag is the control; the 409 only stops that
control being granted unread. Spec 110's authority row and A3 now say so — the
trifecta's second leg is *narrowed to a set the operator names*, not broken,
because inside a shared Project all three legs remain.

**FIND-001 turned on picking the right gate, not on adding one.** `/undo` and
`/delete` are restricted to the **primary chat**. The Project flag answers "where
may work happen"; these act on the operator's own history and Checkpoints, so
gating them on it would still have left them reachable by any group member in any
opted-in Project. `/undo`'s gate lives inside `Restore-DpIntercomCheckpoint` — the
function that rewrites files — rather than only at its single current caller.
`/archive` stays open to the group: `/unarchive` undoes it, it writes nothing to
disk, and `/chats` already exposes the list.

**FIND-004 and FIND-005 got the one structural fix.** `Send-DpIntercomMessage`
re-validates its resolved target against the live allow-list through the new
`Test-DpIntercomChat`, falling back to the operator's chat and recording a dropped
`misrouted` message. Enumerating every place that stores a chat id was the
alternative, and failing to enumerate one *is* the bug — which is how the queued
prompt and the in-flight `Download` were both missed. The clearing logic was kept
and completed anyway, as defence in depth, with `Clear-DpIntercomDownload`.

Also closed: the audit log now carries the chat and sender on every inbound line
(FIND-003) — data `ConvertFrom-DpIntercomUpdate` had computed and discarded since
day one — surfaced through `Get-DpIntercomPayload` and rendered in the Status
panel; both `getMe` paths log `identity-error` instead of swallowing (FIND-006);
and both chat-id patterns are bounded by a real `[long]::TryParse` rather than a
digit count (FIND-007), tightened together so one key cannot accept what the other
rejects. No changelog entry for the last one — Telegram cannot issue a 20-digit id.

**One defect was found by the suite, not by the tests written for it.**
`Test-DpIntercomChat` read `$Settings.intercom` directly. Under StrictMode a
missing key throws, and the function now sits on `Send-DpIntercomMessage` — the
path that reports a finished job, which is the *same* failure this codebase has
now learned three times. Ten existing tests went red with
`PropertyNotFoundException`. The lesson recorded in `systemPatterns.md`: **a new
function inherits the failure mode of the path that calls it**, so adopt that
path's rules before wiring it in. Two existing fixtures were also corrected rather
than worked around — they asserted group routing without allow-listing the group,
which the re-validation now correctly refuses.

Red-first was proved, not assumed: the 40 new tests in
`tests/Unit/IntercomAuthority.Tests.ps1` ran against a detached worktree at
`54baab6` and came back **11 passed / 29 failed**. The 11 passing are exactly the
positive counterparts — `/delete` for the operator, `/archive` from the group, the
status message pinned, a valid id accepted — which is what proves the refusals are
not passing because the branch is unreachable. Gate: **1433 tests, 0 failures**,
16 tasks, 0 warnings. PSScriptAnalyzer no new findings across all 13 changed
production files, confirmed against the same baseline commit. `node --check` clean.

## Previous focus — opening a file with the OS program

**A file DeskPilot cannot show opens in the program the computer already uses
for it (2026-08-31, uncommitted on `main`).** Asked as "files in the right file
pane should be openable with the program that is assigned to the file type by
os. excel files cannot be shown in the dp preview but when trying to opening it
there should be a question with a (keep this setting checkbox) to use the
assigned app. there should be also a way to remove the saved preference."

The file viewer had one dead end for anything binary — *This file can't be
previewed as text* — so a spreadsheet in the Project was readable only by its
name. Clicking one now loads the viewer as before, and the moment it reports the
file is binary and not an image the question is raised: **Always open .xlsx
files this way**. New `POST /api/fs/open` hands the file to the platform's own
association; the new Setting `externalOpenTypes` holds the types the user chose
to keep, and Settings › General lists each one with a ✕ plus **Forget all**.

Six decisions. **(1) An executable or script type is refused, not confirmed.**
`Get-DpExecutableExtension` is the whole class — `.exe`, `.bat`, `.ps1`, `.sh`,
`.lnk`, `.jar`, `.py`… — and `Start-DpExternalFile` rejects it with `403
executable` with no dialog that gets past it and no Setting that whitelists one.
The agent writes into the same folder the tree lists, so `budget.xlsx.exe`
must not be one click from running; the deny-list also gates the *Setting*, so a
type that can never be opened can never be remembered either. **(2) The file
type is an allow-shape, not a deny-list**: `^\.[a-z0-9]{1,16}$` on the resolved
extension, which removes alternate data streams (`notes.txt:run.exe`) and
trailing-junk padding as a class rather than enumerating them. **(3) The launch
is the ShouldProcess operation**, so the whole gate is testable under `-WhatIf`
without a program appearing on the machine running the suite; the route test
mocks `Start-DpExternalFile` for the one success case. **(4) No shell, no
arguments.** Windows gets `UseShellExecute` on the path; elsewhere the path is a
single `ArgumentList` entry to `open`/`xdg-open`, so a name with spaces or
quotes is never re-split. **(5) Nothing is remembered for an open that failed** —
`confirmAndOpenExternally` stores the type only after `openFileExternally`
returns true. **(6) Declining is not a dead end**: the same offer stays on the
panel (`buildNoPreviewPanel`), and every file has an **↗** in the viewer head, so
a Markdown file or an image can be opened in the user's own editor too.

Verified: full Sampler `build, test` **1348/1348**, 0 failed, 16 tasks, 0 errors,
0 warnings (run in a clean `pwsh` — an interactive session with two Pester
versions loaded makes Sampler skip both Pester tasks and report a green build
that ran nothing). `node --check` clean; PSScriptAnalyzer clean on the new files.
Red proven against `HEAD`: `git show HEAD:source/web/assets/app.js` matches none
of `confirmAndOpenExternally|api/fs/open|externalOpenTypes`.

**Follow-up — the viewer goes full screen (2026-09-01).** Asked as "can we also
have a maximize window button?", then "lets make it really full screen. There is
still a big margin". The first cut set `width: 96vw; height: 94vh` and left a
visible inset, and the reason was not the 4% — `.modal` centres itself with
`transform: translate(-50%, -50%)`, and **no width can close a gap a translate
re-introduces**. `.file-modal.is-maximized` now clears the transform, pins
`top/left: 0`, takes `100vw × 100vh`, and drops the border and radius; the body's
side margins and rounded frame go with it, while `.file-content`'s own padding
still keeps text off the glass.

One control, two states: the glyph stays `⛶` and the title/`aria-label` flips
between **Maximize** and **Restore down** with `aria-pressed` carrying the state,
which avoids a restore glyph that renders as a box on fonts without it. The
choice lives in `localStorage` under `ad_filemax`, beside `ad_theme`, and
`applyFileViewerSize()` runs on every `openFileViewer` — it is a window
preference, not a per-file one.

**Measured, not asserted from the CSS.** Rendered in headless Edge against the
real `styles.css`: `viewport [1570, 805]`, `modal [0, 0, 1570, 805]`,
`gap { left: 0, top: 0, right: 0, bottom: 0 }`, `radius 0px`. The `WebAssets`
guard now asserts `transform: none`, `width: 100vw` and `max-height: 100vh`
inside that rule specifically, so restoring the centering fails a test rather
than silently re-inserting the margin. Gate **1349/1349**, 0 errors, 0 warnings.

## Previous focus — attachments are chips

**Attachments are chips on the message, not a sentence inside it (2026-08-25,
`ai/attachment-chips`).** Asked from two screenshots — DeskPilot's own bubble
opening with "I attached 2 file(s) in the Workspace Folder: …" beside GitHub
Copilot Chat's chips above the message — as "DP attaches files like on
screenshot 1 to the chat. Can we rather do that like GHCP is doing it in
screenshot 2?"

The note was composed in `send()` and prepended to the prompt, so it was the
user's message: read back in their own bubble, used as the conversation title
(`Invoke-DpTurn` titles from the first 60 characters of the prompt), replayed on
regenerate, and handed to them again in the edit box. The paths now travel
beside the prompt. `POST /messages` accepts `attachments` (paths from
`/api/uploads`), records them on the user Message as `{ name, path }`, and the
new pure `Get-DpAttachmentNote` composes the model-facing line that
`Invoke-DpTurn` prepends to the **Engine** prompt only.

Six decisions. **(1) The Message keeps the user's words; `$enginePrompt` is a
separate value.** Everything the user sees or edits reads `text`; only
`New-DpTurnParameter`, the fallback history and the stopped-Turn cost estimate
read `$enginePrompt`, so the three places the note actually has to reach get it
and no display path does. **(2) The Host Server decides the form of the path,
not the browser.** It knows whether the file is inside the Workspace Folder, so
a file in the Project is named relative to it (the Engine's working directory,
which is what its File Tool resolves) and anything else — an upload made with no
Project selected — by its absolute path; the client used to guess from
`state.settings.workspaceFolder`, which is right about the *upload directory*
and says nothing about a given file. **(3) The same upload-store gate as Vision
input.** `Resolve-DpAttachmentPath -AnyContentType` drops only the `image/*`
requirement, so a crafted Message still cannot nominate an arbitrary local file
for the agent to read — the paths reaching the model are exactly the ones this
launch wrote. **(4) A Turn may be attachments and nothing else.** Dropping files
and pressing Send is a request about those files, so the empty-prompt check now
fires only when there is neither; `$Prompt` gained `[AllowEmptyString()]`, the
bubble is omitted rather than rendered empty, and the title falls back to the
file names. **(5) Re-runs carry the files.** With the note out of the text, a
regenerate or an edit would silently drop them, so both routes read
`attachments` off the stored Message **before** `Reset-DpConversationForRerun`
truncates it. **(6) The chips are built from the Message, not from
`state.pendingAttachments`,** so they survive a reload, an edit and a
regenerate; `textContent`/`title` only, never `innerHTML`.

Verified: full Sampler `build, test` **1308/1308**, 0 failed, 9 tasks, 0 errors,
0 warnings; `AttachmentRoutes` re-run **19/19** after the last handler edit;
`node --check` clean on `app.js`; PSScriptAnalyzer clean on the changed files
(the two `PSUseBOMForUnicodeEncodedFile` warnings are pre-existing). Red proven
against `HEAD` rather than assumed: `HEAD:app.js` still contains the injected
note the new assertions forbid, `HEAD`'s route handler does not read
`attachments`, and `Get-DpAttachmentNote` does not exist there at all.

**Follow-up (2026-08-25, uncommitted on `main`):** that gate ran on Windows only.
CI at `d88542b` failed the `Test` leg on `ubuntu-latest` and `macos-latest` with
two `Get-DpAttachmentNote` cases, because the Describe fed the function
`C:\projects\demo\…` literals — on POSIX a relative name whose backslashes are
ordinary characters, so nothing lands inside the Workspace Folder. The function
is correct and unchanged; the tests now build their root from the running
platform. See `progress.md` and the path-literal pattern in `systemPatterns.md`.

## Previous focus — an image is shown as a picture

**An image is shown as a picture instead of "there is no text to compare"
(2026-08-24, uncommitted on `main`).** Asked from a screenshot of the Diff
viewer over four untracked `.jpg` files and four `.msg` files: "of course we
cannot display every binary format, but can we show a preview of the usual image
formats like gif, jpg, png, etc." The viewer had one message for every file it
could not diff, so a screenshot the agent had just saved was reviewable only by
its name.

Both previewers now show the picture: the Diff viewer for a new binary file and
for a tracked one git reports only as `Binary files … differ`, and the file
viewer where it used to say the file cannot be previewed as text. Anything else
keeps the words. New `GET /api/fs/image` returns the raw bytes; `Get-DpFileImage`
confines the path to the Project exactly as `Get-DpFileContent` and
`Get-DpGitDiff` do, and `Get-DpImageMediaType` decides the type.

Five decisions. **(1) The signature bytes decide the media type, never the
extension.** The endpoint serves user-controlled bytes back into the app's own
origin, so `trap.png` containing `<script>` is refused rather than labelled
`image/png`. **(2) SVG is deliberately not previewable.** It is script-capable
markup, and being text it already diffs and reads as text — excluding it removes
the whole class of risk instead of filtering it. Every response now also carries
`X-Content-Type-Options: nosniff`. **(3) The token travels in the query.** An
`<img>` cannot send `X-DeskPilot-Token`, and the session gate already accepts
`?t=` — the same way the served entry URL carries it — so the endpoint is no less
authenticated than the rest of `/api/*`. **(4) There is no before/after.**
Reading the old blob would mean a byte-safe `git show`, which `Invoke-DpGitCommand`
cannot do (it returns decoded strings); the preview is the file as it stands now,
and the caption says which. **(5) An over-size file is refused, not truncated** —
half an image is not an image — and the file viewer no longer claims a
"truncated" preview beside a complete picture, since the 1 MiB cap belongs to the
text read.

A missing or unservable file falls back to the same message through the `<img>`
`onerror` handler, which is what covers a deleted image without a second code
path.

Verified: 926/926 unit tests across the three affected files (13 new), 47/47
`WebAssets`, `node --check` clean, PSScriptAnalyzer clean (the two findings are
pre-existing and reproduce on `HEAD`).

## Previous focus — a Turn in the order it happened

**A Turn is laid out in the order it happened, with the answer last (2026-08-24,
uncommitted on `main`).** Two rounds. The first moved the reasoning from above
the answer to below it, and the screenshot of the result showed why that was only
half an answer: the answer body still grows in one place, so *all* the boxes pile
up on whichever side of it they are put — the first round put them above, the
second put them below, and both are wrong for the reasoning that happened on the
other side of some prose. The requirement, stated plainly the second time, is
chronology: "break up the reasoning so it does not pile up but rather continues
in a new box after the output… the output may also be broken into several
sections as long as we have one full summary at the end."

The message is now `role, steps, turn-flow, content, …`. The **flow** is the Turn
as it happened — a `.thinking` box per run, and a `.flow-answer` block holding the
prose the model emitted between two runs — and `content` below it is the one full
summary.

Five decisions. **(1) The two boundaries are different frames and both are
needed.** A `delta` with text seals the open run (`if (t && think) {
sealThinking(wrap); think = ''; }`) — otherwise the trace stays open above the
answer it was reasoning towards. A `reasoning` frame arriving with answer text on
screen calls `flushAnswerChunk`, which moves that text into the flow and empties
`content` — that is what puts the prose *above* the run it led to. Doing both in
`delta` cannot work: at that moment there is no next run to be above.
**(2) The last chunk is never flushed.** `finalizeAssistant` overwrites `content`
with `m.text`, and since `Invoke-Shp` returns only the final iteration's content,
that is exactly the summary — no duplication and no reconstruction needed.
**(3) `.thinking:last-child`, not `lastElementChild`.** It returns null when the
flow ends in a flushed chunk, which is precisely what makes the prose a boundary
a later run cannot grow back through. **(4) Steps is suppressed when the flow
carries the narration** (`r.flow.querySelector('.flow-answer') ? null :
m.narration`), or the same prose prints twice — inline and again in the
disclosure. A thread rebuilt from storage has no flow, so Steps still does its
job there. **(5) With `showThinking` off none of this activates**, because the
Engine only emits `reasoning` frames under `-ShowThinking`: no runs, no flush, no
chunks, and Steps behaves exactly as before.

Carried over from the first round: a live box streams open and folds on seal
(`showThinking` no longer decides, since it was always true for a live box); a
`summary` click sets `data-touched` and `sealThinking` skips those, so a box the
reader opened is not shut under them; `showInlineError` seals, or a Turn that
dies mid-reasoning leaves a box open and unlabelled forever; a sealed box reads
`Thought for Ns`; and `renderStoredThinking` returns early on
`flow.dataset.live === '1'` so the flat stored trace never overwrites the live
layout.

Red proven first in both rounds. Round two: 43/43 in `WebAssets.Tests.ps1`.

## The scroll that stopped short

Reported twice, and the first diagnosis was wrong. Round one read "there is more
content below but the scroll bar is already at the end — I can go there when
selecting the text and moving down with the mouse" as a scroll *position* short
of the bottom, and fixed two real things on that basis. Round two arrived with
two screenshots that showed what the bar actually was.

**The bar at the end was the Thinking box's own.** While a run streams, the box
sat in the middle of the flow with the answer body and the Activity panel below
it, and `.thinking .disclosure-body` carried `max-height: min(46vh, 420px);
overflow: auto`. A wheel over a box that scrolls itself never reaches the thread
— Chrome latches the gesture to the inner scroller — so the reader hit the end of
the *box's* bar with the rest of the message out of reach, while drag-select
auto-scroll (which targets the thread) got there. The screenshot shows it
exactly: the box's own thumb is at the bottom of its own track, and the caret
block and Activity panel that follow it are not on screen.

Fixed by making the live box **clipped, not scrollable**:
`.thinking:not([data-sealed="1"]) .disclosure-body` is `max-height: 220px;
overflow: hidden`, and `renderThinking`'s existing `body.scrollTop =
body.scrollHeight` pin still keeps the newest line in view — a programmatic
scroll works on an `overflow: hidden` box. A **sealed** box keeps `min(46vh,
420px)` and `overflow: auto`, because opening a finished run is the reader's own
choice and nothing is moving. Measured against the real stylesheet in headless
Edge: live `{ clientH: 220, userScrollable: false, pinnedToNewest: true }`,
sealed `{ clientH: 370, userScrollable: true }`. Halving the live height also
stops one box filling the window on its own.

Two other real causes were fixed in round one and stay. **(1) The follow was
animated:** `scrollThread()` assigned `scrollTop = scrollHeight` while `.thread`
carries `scroll-behavior: smooth`, and `followThread()` re-aims at the bottom on
every streamed frame — an animation restarted every ~16 ms trails the content.
It now uses `scrollTo({ …, behavior: 'instant' })`; `revealThinking`'s
`scrollIntoView` still asks for `smooth`. **(2) The thread grows after the last
follow:** `done` follows, and *then* the `finally` runs
`refreshCurrentConversation()` → `syncCheckpointDividers()`, and
`maybeAutoCompact()` can rebuild the thread outright, so a final `followThread()`
now sits after everything in both runners' `finally`.

**Two hypotheses were measured and killed**, which is why the third was found.
The static layout is sound — `.app` does not overflow `100vh` and a tall message
leaves 34 px of clearance above the composer. And a full simulated Turn driving
the *real* `wireThreadFollow` logic (reasoning runs, seals, chunk flushes,
activity frames, answer bursts) ends with `threadFollow: true` and
`gapFromBottom: 0`, so neither the collapsing boxes nor `flushAnswerChunk`'s
clear-and-append kills the auto-follow. The animation lag itself remains
inference: under `--virtual-time-budget` a smooth scroll completes between
frames, so old and new both measure a zero gap.

Found while fixing it: **chunking introduced a real regression in `renderLive`.**
A paint scheduled by the last `delta` can land *after* `done` has written the
final answer, and `raw` is now only the chunk since the last run of thinking — so
that late paint truncated the answer. Both runners now bail on `turnCompleted`.

## Previous focus — image Attachments

**Image Attachments no longer overflow the Turn's request body (2026-08-24,
uncommitted on `main`).** Reported as a Turn dying with `Exception calling
"EndInvoke" with "1" argument(s): "Request Entity Too Large"` while the same
photos worked in Copilot Chat. The 413 came from the Copilot endpoint, not the
Host Server: nothing on the Vision path budgeted bytes, so a full-resolution
camera JPEG went on the wire inflated ~4/3 by base64 (the Engine's
`ConvertTo-ShpImageContent` reads the file and inlines a `data:` URI). The upload
route's 25 MiB cap is per file part, not per request. **ShellPilot needed no
change** — it faithfully sends what it is given; the missing budget was
DeskPilot's.

Five decisions are load-bearing. **(1) The browser makes it work, the Host
Server makes it safe.** The SPA downscales an over-budget image through a canvas
before uploading (long edge 1568, ~1.5 MB, quality 0.82), but the browser is not
a trust boundary and an Attachment also arrives from Intercom, so
`Get-DpVisionBudgetError` enforces 3.5 MB per image and 8 MB per Turn against
the bytes on disk. The client budget is deliberately tighter than the server's,
so anything the browser shrank always passes. **(2) Only an over-budget image is
touched.** Re-encoding a file the user attached, for no gain, is a silent edit
of their data; a PNG also keeps its codec, because JPEG ringing is worst on the
screenshot text that is the usual reason for attaching one. **(3) Animation is
sniffed, not inferred from the MIME type.** A canvas re-encode keeps one frame;
GIF is excluded outright, but animated WebP and APNG share their still form's
MIME type, so the header is scanned for `ANIM`/`acTL`. The independent review
caught this — the first cut excluded only GIF while the CHANGELOG promised
animated images were safe. **(4) The refusal happens before the Turn starts**,
as `413 too_large` naming the file and its real size, rather than paying a round
trip for a bare endpoint 413 that arrives as a raw `EndInvoke` string.
`Test-DpTransientEngineError` correctly does not match 413, so Retry never
resends an identical oversized body. **(5) A refused Turn hands the work back.**
`send()` clears the composer and the Attachment chips *before* the request
opens, so making a pre-Turn rejection reachable for the first time would have
destroyed the user's prompt; `_runTurn` now reports whether the server's `start`
frame ever arrived, and `send()` restores both when it did not.

Also from review: sizes format with `InvariantCulture` (a `de-DE` host would
have rendered `3,5 MB` and broken every caller matching on it),
`createImageBitmap` passes `imageOrientation: 'from-image'` so an older engine
cannot bake a portrait phone photo in sideways, and a file that vanished or
locked between validation and the size check is skipped rather than thrown —
that path surfaced as a 500 quoting the absolute path.

Red proven before green in throwaway worktrees at `HEAD`, twice: 9/9 new tests
failed without the fix, and the Intercom guard was isolated separately (without
it the 4 MB photo really is handed to Vision). Final Sampler gate
`./build.ps1 -Tasks build, test`: **1272/1272**, 0 failed/skipped, 16 tasks,
0 errors, 0 warnings. Left uncommitted at the user's request.

## Previous focus — pasting a file into the chat

**Pasting a file into the chat is fast again (2026-08-24, uncommitted on
`main`).** Reported as "when pasting files from the clipboard using Ctrl+V it
takes quite some time until they appear in the chat". Measured before touching
anything: `Read-DpMultipartParts` took **1817 ms** for a 5 MB body, linear in
size. Two causes, and the second was not the obvious one.

**(1) The boundary scan walked every byte in interpreted PowerShell.** Replaced
with a Latin-1 view of the body (`Encoding::Latin1` is a one-to-one byte↔char
map, so it is byte-exact) and `String.IndexOf(…, Ordinal)`, which is a vectorised
native scan: 297 ms → **11 ms** for the same body. An intermediate attempt using
`[Array]::IndexOf` on the delimiter's first byte was only 27× worse than that,
because random binary yields ~20,000 candidate positions per 5 MB and each one
costs a full interpreted loop iteration. The payload is still copied from
`$Bytes`; it never round-trips through the string.

**(2) The real cost was `$content = if (…) { [byte[]]::new($n) } else { … }`.**
Assigning the result of an `if` **statement** sends its value through the
pipeline, which **unrolls a `byte[]` into a boxed `object[]`**. A 5 MB upload
became five million boxed bytes: **737 ms** in `Array.Copy` alone, ~200 MB of
garbage, and `$part.Content` typed `System.Object[]` in a function whose
docstring promises a byte array — so `File.WriteAllBytes` then paid another full
conversion. Fixed by assigning `[byte[]]::new(…)` directly. **This idiom is worth
hunting for elsewhere in the codebase.**

**(3) `Receive-DpHttpRequest` decoded every body as UTF-8**, including megabytes
of binary, for a `$body` string that only the JSON path reads — and
`Invoke-DpRequest` already skips multipart there. Now gated on the content type;
that alone was ~790 ms per 5 MB paste. Its truncated-read path also used
`$bodyBuffer[0..($offset - 1)]`, which materialises an int range array and
indexes element by element, and produced garbage for a zero-byte read; replaced
with `Array.Copy`.

Net: the parser body is **6 ms** for 5 MB, down from ~816 ms. One trap found
while testing: the repo's own `New-MultipartBody` test helper ended with a bare
`$ms.ToArray()`, hitting the *same* unroll, so the perf test was timing an
`object[]`→`byte[]` conversion the real caller never performs. It now returns
`, $ms.ToArray()`.

## Previous focus — closing a Conversation

**Starting a new Conversation now closes the open one (2026-08-24, uncommitted
on `main`).** Reported as "when clicking on **+ New conversation**, the current
conversation should be closed and a new chat started — right now the current chat
stays active". *Active* was the precise word: `newConversation()` was the only
Conversation-switching entry point **without** a `state.streaming` guard, while
`goHome()`, `regenerateTurn()`, `startEditMessage()` and `restoreCheckpoint()`
all had one. Clicking it mid-Turn flipped `state.current` to the new Conversation
and re-rendered the thread, but the Turn kept running underneath: `stopTurn()`
posts to `state.current.id`, so **Stop** would have targeted the new chat rather
than the working one, and `flushDispatchQueue()` fires `_runTurn` against
whatever is current when the old Turn's `finally` block reaches it — so a message
queued for the old chat was delivered to the new one.

Three decisions. **(1) The close lives in `newConversation`, not at the call
sites.** The button, the command palette entry and Ctrl+Shift+O all route through
it, and putting the logic in one place is what keeps the three consistent.
**(2) `if (!state.current) return true` is what makes that safe.** Four internal
callers reach `newConversation()` without a user gesture — startup,
`deleteConversation`, `send()` with nothing open, and
`syncConversationsFromServer` — and the three that could be mid-Turn all null out
`state.current` first, so they skip the close entirely instead of awaiting a
stream end that may never be theirs. **(3) It confirms, then waits.** Ending a
Turn on a mis-click of a prominent sidebar button is not silent; the dialog says
the partial answer is kept on the Conversation being left. The wait reuses the
`dispatchStopAndSend` pattern — capture `state.streamEndPromise`, `await
stopTurn()`, `await ended` — because the Turn's own `finally` resolves that
promise **before** it runs `refreshCurrentConversation()` and
`flushDispatchQueue()`. Clearing `state.dispatchQueue` before returning is what
makes the later flush a no-op rather than a delivery into the new chat.

Not changed: the composer draft and pending Attachments survive, because typing
something and then deciding it belongs in a new chat is a real workflow.
Hover-reveal, sidebar selection and `goHome()`'s refuse-while-streaming were left
as they are.

## Previous focus — copying a prompt mid-Turn

**A prompt can be copied while its Turn is still running (2026-08-24,
uncommitted on `main`).** Reported as "we need a little copy icon / button for
quickly copying prompts in the chat — right now there is nothing like that",
then corrected to "we have already a copy icon somewhere else that we should
reuse". Both readings were right about something. The icon existed — `⧉` on a
`msg-action-btn` — but it was hand-rolled **twice**, once in `buildUserEl` and
once in `buildMessageActions`, and the user-side copy sat behind
`if (m && m.id && m.text)`. `_runTurn` builds its optimistic bubble as
`buildUserEl({ text: displayText, dispatch })` with **no id** — the id only
arrives later on the `start` frame — so for the entire length of a Turn the
prompt on screen offered no copy at all, and the affordance reappeared only
when `refreshCurrentConversation` re-rendered the thread at the end. The report
was therefore accurate for the exact moment a user is most likely to want the
prompt back.

Three decisions. **(1) One builder, not a third icon.** `buildCopyButton(onCopy)`
is the single place the icon is constructed, and a test asserts
`copy.title = 'Copy message';` appears exactly once in `app.js` — the drift that
let the two sides diverge in the first place is now a failing test rather than a
review question. No new SVG was drawn; the existing glyph is reused, as asked.
**(2) The gate was split by what each action actually needs.** Copy needs the
text, so it is offered whenever there is text; **Edit & resend** re-runs the
Conversation from a stored message and still requires `m.id`. Gating both on the
id was a single condition doing two unrelated jobs. **(3) Hover-reveal was left
alone**, because `.msg-user:hover`/`:focus-within` is the established pattern for
both sides and the reported gap was absence, not discoverability.

Gate: **1242/1251**, 0 errors, 0 warnings. The 9 failures are all Engine
registration tests and are **environmental, not a regression** — the host is now
PowerShell **7.6.3** (the previous 1250/1250 was 7.5.5) and
`Get-Module ShellPilot -ListAvailable` returns nothing under it. Only three
files changed, none of them PowerShell source. Both facts are recorded in
`debugging-insights.md`, together with the `DeskPilot.psm1` *used by another
process* lock — which is the previous run's test-phase import, cleared by
running `-Tasks build` alone first, not by deleting the output folder.

## Previous focus — Branch integration

**All four feature Branches are integrated into `main` (2026-08-13).**
`ai/discard-all-changes`, `ai/live-activity-feed`, `ai/mcp-servers` and
`ai/response-auto-retry` formed one linear chain — each Branch's tip was the
next one's base — so integration was two moves rather than four: `main`
fast-forwarded to the MCP tip, which already contained the first three, and then
took the retry Branch as a merge commit. The only conflicts were in this file
and `progress.md`, where both sides prepended a record to the same position;
both records were kept rather than either being dropped. The Branches were
deleted locally only after `git branch -d` confirmed each was contained in
`main` — the safe deletion that refuses to discard unmerged work.

Nothing in `source/`, `tests/` or `specs/` had to be reconciled: because the
chain was linear, the retry Branch's tree already contained every MCP, live
Activity and Discard change, and `git diff 08e3ad5 e0566d8 -- source tests
specs` is empty. Verified on the merged `main` with the authoritative Sampler
gate, `./build.ps1 -Tasks build, test`: **1250/1250**, 0 failed, 16 tasks, 0
errors, 0 warnings. The first two gate runs failed on `DeskPilot.psm1` being
*used by another process* — the environmental build-output lock already recorded
for 2026-07-08, not a code fault; it cleared after removing
`output/module/DeskPilot` and letting one build run alone. `main` is 9 commits
ahead of `origin/main` and unpushed.

## Previous focus — response retries

**Response retries are now configurable and side-effect safe
(`ai/response-auto-retry`, 2026-08-13).** The reported interruption was GitHub
Copilot Chat repeatedly ending with *"Sorry, no response was returned"* until
the user pressed Retry enough times. DeskPilot already retried a narrow set of
transient failures, but the count was hard-coded at two retries and an empty
successful Engine result was deliberately classified as unrelated. The new
`responseRetryCount` Setting means **extra attempts after the first** (`0–100`,
default `2`, so existing behavior is preserved) and is exposed as **Response
retries** in General Settings; old partial `settings.json` files inherit the
default through `Import-DpSettings`.

Five decisions are load-bearing. **(1) Empty is retryable only before anything
streams.** `Test-DpEngineResultRetry` combines the empty-result test with the
Turn's emitted-frame count. Once answer text or Tool Activity exists, a blank
final answer stays on the ordinary completed path so Activity, pending changes,
Undo and Usage are preserved; restarting then could repeat a command or write.
This relies on ShellPilot emitting its structured `ToolCall` progress record
before executing the Tool. **(2) Known empty-response errors and a null/blank
pipeline result share the same policy.** `Test-DpTransientEngineError` recognizes
the former; `Test-DpEmptyEngineResult` recognizes the latter. A real 401 remains
non-transient. **(3) Backoff is bounded and cancellable.** Each wait grows from
400 ms but caps at 5 s, and `Wait-DpResponseRetry` pumps pending Host Server
requests every 50 ms so Stop remains responsive. **(4) Failed attempts are not
free.** If the Engine records more than one call, `Merge-DpRetriedTurnUsage`
uses the exact pre/post summary delta for tokens, cost and credits; the summary
does not expose failed calls' internal iteration counts, so iterations are a
documented conservative minimum. **(5) Successful Usage keeps its normal
shape.** Missing summary fields preserve the final result's pricing rather than
turning a priced Turn into an unpriced one.

The implementation was developed red/green in focused slices and independently
reviewed twice. The first review found that an unconditional empty-result throw
would have dropped Activity and pending-change tracking after Tool work; the
new behavioral predicate test caught and guards that case. The scoped re-review
approved the corrected design with no Blocker or remaining Major finding. Final
Sampler `build, test`: **1250/1250**, 0 failed/skipped/not-run, 16 tasks, 0
errors, 0 warnings.

## Previous focus — the MCP Branch was synchronized with `main`

**The MCP Branch is synchronized with `main` (`ai/mcp-servers`, 2026-08-13).**
Local `main` merged the latest `origin/main`, then the MCP Branch merged local
`main`. Git reported no text conflict, but self-review found a semantic one:
the incoming `0.4.0` heading landed above the MCP, live Activity, and Discard
entries, incorrectly placing those unreleased changes in the released version.
The three feature-Branch entries remain under `[Unreleased]`; the `0.4.0`
boundary now starts immediately before the older parity-eval entry. Git checks
confirm `main` is an ancestor, the worktree has no unmerged entries, and the
resolved heading order is unique and correct.

## Previous focus — MCP servers

**MCP servers can now be attached (`ai/live-activity-feed`, 2026-08-12).** The
Engine gained MCP in ShellPilot **0.4.0-preview0007** (`Register-ShpMcpServer` /
`Get-ShpMcpServer` / `Unregister-ShpMcpServer`, `Invoke-Shp -DisableMcp`,
`Origin`/`Server` on `Get-ShpTool`, `McpEnabled`/`McpToolsAvailable`/
`McpToolsCalled` on the result), which was the blocker recorded in
[060-roadmap](../specs/060-roadmap.md) and gap 3 of
[100-competitive-landscape](../specs/100-competitive-landscape.md). This is the
DeskPilot half. Six decisions worth keeping.

**(1) DeskPilot owns the durable list because the Engine deliberately owns
none.** An Engine registration lives only for the life of the session and the
Engine refuses to discover a configuration file on its own — a repository anyone
can open must never be able to start a process. So `settings.json` holds the
rows and `Sync-DpMcpServer` carries them into the long-lived Engine Runspace at
startup and on every save.

**(2) It reconciles, it does not apply.** Attaching starts a third-party
process, negotiates a protocol era and lists tools, so re-attaching everything
on every save would restart working servers for nothing. An unchanged row —
matched on a fingerprint of what actually decides the launch — is left alone; a
**Faulted** one is re-attached, because the Engine deliberately never respawns a
crashed server by itself and a user pressing Save is not an unattended loop.

**(3) Ownership is tracked, not assumed.** A row that names an `mcp.json` may
attach several servers, so the reconciler records the names that appeared while
the row was applied. A live server no row owns is detached: this Runspace has
exactly one configurer, so a survivor is a leftover still contributing its tools
to every Turn.

**(4) Secrets are names, never values.** `settings.json` is clear text.
`envKeys` persists variable *names*; `Get-DpMcpRegisterParameter` resolves the
values from the Host Server's own environment on the way into the registration,
so a settings backup cannot leak a key. The fingerprint covers a **hash** of the
value, so a rotated token re-attaches the server without the secret ever
reaching the fingerprint, a log or the API.

**(5) A capability probe, not a version comparison.** `Initialize-DpEngine`
probes the imported Engine for `Register-ShpMcpServer` and records
`McpSupported`. That stays true across a rename or a backport, and it is what
lets `New-DpTurnParameter` withhold `-DisableMcp` from an older Engine — an
unknown parameter name would fail the whole Turn, so the permission is gated on
the probe rather than on the Setting alone.

**(6) The panel says what the permissions do not.** The Permissions tab limits
DeskPilot's *own* tools; it does not limit an attached server, which can bring
file and shell tools of its own and cannot be sandboxed. `-ToolName` narrowing
is surfaced as *Only offer these tools* because it is the one control that
genuinely reduces reach. MCP tool calls get their own Activity kind (`mcp`) so
the reader can tell whose code just ran, and no detail is derived from their
arguments — the shape is the server's own schema.

One bug caught by its own test before it shipped: an absent `args` key read as
`$null`, and `@($null)` is a one-element array whose element became an empty
string — a real, empty argument passed to every server configured without
arguments.

## Previous focus

**The Activity panel now runs live, in order, and folds into one line
(`ai/live-activity-feed`, 2026-08-12).** Asked for from three GHCP screenshots —
you can see the files it touches as it touches them, then the whole run collapses
to a clickable line — with a follow-up: "the same feature would be nice for
fetching urls". The panel existed but only ever appeared at `done`, built from
the Engine's **unordered sets**, and the only thing named live was a file being
written (the `file` frame, and only for `write_file`/`replace_in_file`). Every
tool call now streams. `Get-DpStreamFrame` sends the whole `ToolCall` record
through a new pure `ConvertTo-DpActivityAction` and emits an `activity` frame
`{ tool, kind, detail }`; the `file` frame is gone, and the client derives the
live edit rows from a `write` action instead. Five decisions worth keeping.
**(1) The order is kept on the Message.** `Invoke-DpTurn` accumulates the actions
it streams and writes them to `activity.actions`, capped at 300 with the overflow
named in a final `dropped` entry — a set cannot say what happened when, or that
one file was read twice, and a **stopped or budget-exhausted** Turn has no Engine
result at all, so until now it reported no activity whatsoever. **(2) The
detail is whitelisted, not copied** — the same map `New-DpTranscriptRecord` uses
(`path`, `url`, `command`, `pattern`, `query`, `name`), because the arguments
carry the written file body; an unknown tool contributes its name only, and
malformed provider JSON costs the detail, never the action. **(3) Consecutive
same-kind actions fold**, not all actions of a kind: six reads in a row are one
moment of the Turn. Groups are open while it runs and closed when it ends, which
*is* the "collapse afterwards" behaviour asked for. **(4) `create_directory` is
its own kind**, not a write — a folder has no diff and is never a pending
change, so treating it as one would put a dead review row on the Turn.
**(5) `manage_todo_list` emits nothing**, because the Task List has its own live
panel. Second half of the request fixed on the way: `pagesFetched` was filled
with the raw tool arguments, so the Activity panel reported `{"url":"…"}` as the
page fetched — the URL is now parsed out. Sampler `build, test` **1156/1156**, 0
errors, 0 warnings.

## Previous focus

**A whole review can now be discarded in one confirmed act
(`ai/discard-all-changes`, 2026-08-12).** The diff viewer — the surface the Git
panel's **Review** button opens over every uncommitted file — offered exactly one
decision, *Undo this file*, so putting a set of eight files back meant eight
round trips through a modal. The footer now carries **Discard all changes**,
which sends every path the viewer is listing to the existing
`POST /api/git/restore`: tracked files go back to HEAD, untracked files are
deleted, and the route already drops the matching pending-change entries so the
panel stops offering an undo for work that is gone. Three choices worth keeping:
it is offered **only over more than one file**, because over a single file it is
the same act as *Undo this file* and two buttons for one outcome is a question
the user should not have to answer; it sits at the opposite end of the footer
from **Close** (`margin-right: auto`), because a mis-click next to the safe
default is how the work actually gets lost; and it **always confirms**, naming
the count, listing the first ten paths and saying that a file which was never
saved has no other copy. No server change was needed. Sampler `build, test`
**1127/1127**, 0 errors, 0 warnings.

**The tool-iteration budget is now approvable, not merely capped
(`ai/maxiter-confirm-above-200`, 2026-08-12).** `Start-DeskPilot` refused a
persisted `maxToolIterations` with `must be 200 or fewer` and started on
defaults; the question was where the 200 came from. Nowhere external — `d10488d`
chose it as an anti-typo guard at 4× the default. It is now the **recommended**
ceiling: the validator's absolute bound moved to **1000**, and the SPA asks for
confirmation above 200, naming both risks (every step is a paid round trip, and a
Turn that long outlives its own session token and dies with an unrecoverable
401). The approval is deliberately **client-side**: `Import-DpSettings` reloads
the persisted file through the same `Merge-DpSettings`, so a server-side
confirmation flag would make an approved value fail its own reload — and one
rejected key discards the entire `settings.json`. Sampler `build, test`
**1126/1126**, 0 errors. The 401 itself is an Engine defect; the refreshed fix
prompt is on the Desktop (`ShellPilot-session-token-refresh.prompt.md`).

**CI is green on all three runners (`ai/fix-cross-platform-path-tests`,
2026-08-12).** The parity series shipped with a red CI: run `31565886477` passed
`windows-latest` and failed `ubuntu-latest` and `macos-latest` on the same six
unit tests. Nothing in `source/` was wrong — two tests encoded Windows path
semantics. `Get-DpTranscriptPath`'s Describe passed `'C:\data'` into `Join-Path`,
which resolves a **provider** path and therefore reads `C:` as a drive
qualifier: on a runner with no `C:` PSDrive it throws `Cannot find drive`, in the
function *and* in the test's own expected values, so all five of its tests died.
It now uses `$TestDrive`. And `Resolve-DpWorkspacePath`'s traversal case
`..\outside.txt` is only a traversal on Windows — elsewhere a backslash is a legal
file-name character and the candidate genuinely stays inside the root, so the
resolver was right and the assertion was wrong; it moved to its own
`-Skip:(-not $IsWindows)` test. Confinement is untouched, because
`Get-DpSearchPatternError` normalises `\` to `/` and refuses `..` by shape on
every platform. Windows `build, test`: **1124/1124**, 0 failed, 0 errors.

## Previous focus — parity with VS Code Copilot

**Closing the measured gap to VS Code Copilot (`main`, 2026-08-11/12).** Asked
for from screenshots of both harnesses running the *same*
handoff prompt, same Model, same Agent: DeskPilot answered defensibly for 30.13
credits and 9 tool actions against GHCP's 231.9 credits and dozens — but it
skipped the authoritative `./build.ps1 -Tasks test` gate and never emitted a
PRE-FLIGHT banner. Diagnosis separated *shown less* from *did less*; the plan
lived in `C:\Users\install\Desktop\DeskPilot-Parity-Prompts` (ten prompts,
00-README carries the evidence table). Eight have shipped — the series is
complete except for prompt 07's fix, which the user chose to leave unwritten.
**All of it is on `main` as of 2026-08-12**: the five topic branches
(`ai/parity-03-workspace-context`, `-04-search-tools`, `-05-edit-tool`,
`-08-turn-transcript`, `-09-eval-harness`) were a linear chain, so main
fast-forwarded to `9dd0390` in one move and is **5 commits ahead of
`origin/main`, unpushed**.

- **The narration was streamed and then deleted.** `Read-ShpChatStream` echoes
  assistant `content` on EVERY tool-calling iteration, but `Invoke-Shp` returns
  only the last iteration's content and `finalizeAssistant` replaces the whole
  message body with it on `done`. Every word the model said while working was
  destroyed at the moment the Turn completed — the single largest reason a
  finished Turn showed far less than it did. `Add-DpNarrationBlock` seals the
  buffered answer text at each **tool-call boundary** (the Engine writes content
  deltas before it dispatches that iteration's tool calls, so the boundary is
  exact; subtracting the final answer instead would fail on a retry, on a
  coalesced frame, and on any answer that repeats itself). Bounded at 32 KB,
  oldest blocks replaced by a marker that states how many are missing. Rendered
  as a collapsed **Steps** disclosure, deliberately **not** gated on the Thinking
  Setting — this is answer text the model chose to emit, and hiding it behind a
  debugging toggle is what let it go unnoticed.
- **Workspace-wide instructions were never in force.** The Engine injects
  instructions as a *catalog* and waits for a `load_instruction` call the model
  measurably often does not make, so `applyTo: **` files — pre-flight,
  post-flight — were simply not applied. `Get-DpAlwaysOnInstruction` pushes the
  bodies of unconditional instructions (`**`, `**/*`, `*` — nothing scoped, and
  nothing that declines to say when it applies) into the system prompt, bounded
  at 24 KB, **naming** whatever did not fit rather than dropping it silently. The
  read happens once per Turn in `Invoke-DpTurn`, not inside
  `New-DpTurnParameter`, which stays free of disk I/O like its
  `AgentSystemPrompt` and `AgentMemory` siblings. Setting `pushInstructions`,
  default on.
- **The iteration budget was low, invisible, and fatal.** Default 25 → **50**,
  now bounded at 200 so a typo cannot start a runaway. The system prompt states
  the cap, because a model that cannot see its budget spends it as if infinite.
  Exhaustion (`Exceeded MaxToolIterations`) was rendered as a bare error string
  that lost the whole Turn; it is now persisted as a stopped Turn that names the
  budget, points at the Setting, and keeps the narration and Task List — which
  only works *because* the narration is now accumulated.
- **The model started every Turn blind.** The Engine's system prompt is
  `'You are a research and coding assistant.'` plus one sentence per tool
  category, and DeskPilot added only the Workspace Folder *path* — so which
  branch, whether anything is uncommitted, and what files exist all had to be
  bought back with discovery tool calls the model measurably often did not make.
  `Get-DpWorkspaceContext` states them up front. Inside a repository the listing
  comes from `git ls-files --cached --others --exclude-standard -z -- .`: faster
  than walking, `.gitignore` honoured for free, Project-relative because `-C`
  chdirs, and `-- .` keeps a Project inside a bigger repository from listing its
  siblings. Over the entry cap the tree is re-rendered one level shallower until
  it fits — deep folders become `name/ (25 files)` — because a truncated tree
  teaches the model that the repository ends where the budget did, and the prose
  states the bound and points at `list_directory`. One 2 s wall-clock budget
  covers everything, and no git call is made with none of it left, since
  `Invoke-DpGitCommand` reads 0 as *wait forever* and this runs on the single
  accept thread. A timeout, or an `ls-files` failure inside a repository, yields
  **no context** rather than a wrong one. Gathered once per Turn in
  `Invoke-DpTurn` while the Runspace is idle, so `New-DpTurnParameter` stays free
  of disk and git I/O. Setting `workspaceContext`, default on.
- **There was no way to search, so it searched rarely.** The Engine's whole tool
  set is `fetch_url`, `read_file`, `list_directory`, `write_file`,
  `create_directory`, `run_command`, `ask_user`, `load_skill`,
  `load_instruction`, `manage_todo_list` — every act of discovery cost a shell
  round trip returning unstructured console text, which is expensive enough that
  the model mostly did not pay it. `search_files` and `search_text` are
  DeskPilot-owned User Tools registered into the Engine Runspace. The
  implementation is not written twice: the backing commands are ordinary
  unit-tested Private functions, and `Initialize-DpSearchTool` re-declares them
  and their dependencies inside the runspace from `(Get-Command x).Definition`,
  because that runspace has ShellPilot imported and DeskPilot not. **The root is
  not a parameter** — every parameter becomes a schema field the model may fill
  in, so it arrives out of band on `$global:DeskPilotSearchRoot`, and so do the
  result cap and the time budget, which are literals for the same reason. Two
  confinement guards: lexical (absolute, drive-qualified, UNC, `~` and `..` are
  refused by shape) and link-resolved (a junction whose final target leaves the
  root is dropped, as is a directory the walk would escape through). `.gitignore`
  is honoured by listing through `git ls-files --cached --others
  --exclude-standard`; `.git`, `node_modules`, `output`, `bin` and `obj` go
  whether tracked or not; binary files are skipped on a NUL byte with a UTF-16/32
  BOM exempted. `truncated` is always reported. Tied to the **File Access**
  Permission through `Set-DpWorkspaceTool`, mirroring `Set-DpQuestionnaireTool`,
  because a registered User Tool is a separate Engine category that
  `-DisableFileAccess` does not reach.
- **Every edit was a whole-file rewrite.** `write_file` overwrites, so changing
  three lines of a 900-line file meant reproducing the other 897 from memory — a
  data-loss risk that is the *expected* outcome at that size, not a hypothetical.
  `replace_in_file` changes one exact block: **exactly one occurrence or nothing
  happens** (zero and several are refused with distinct messages and the file is
  left byte-identical), BOM/encoding/dominant line ending preserved with a
  throwing decoder so a file that cannot round-trip losslessly is refused rather
  than corrupted, and the model may send plain newlines because `oldText` is
  retried converted to the file's own ending. It returns `lineStart`/`lineEnd` so
  the model need not re-read. Confinement is the search tools' — literally: root
  resolution and the per-candidate test moved into `Resolve-DpWorkspaceRoot` and
  `Resolve-DpWorkspacePath`, so search and edit cannot drift apart, and
  `Set-DpSearchTool`/`Initialize-DpSearchTool` became
  `Set-DpWorkspaceTool`/`Initialize-DpWorkspaceTool` over all three tools with one
  root global, `DeskPilotWorkspaceRoot`. **The accounting is the non-obvious
  half:** ShellPilot fills `result.FilesWritten` only from its own `write_file`
  (`:4202`), so an edit made here would be invisible to the Activity card, the
  pending change set and Undo — the tool appends to a Runspace ledger that
  `Get-DpEngineEditedFile` drains into `$mapped.activity.filesWritten` once the
  pipeline is complete. `Get-DpStreamFrame` also emits the live `file` frame for
  it, parsed rather than pattern-matched because `newText` can contain the literal
  text `"path":`.
- **There was no ordered record of a Turn at all.** What happened lived in four
  places nothing could join: live SSE frames that vanish, `ShpProgress` records
  consumed and dropped, `result.ToolCalls`/`FilesRead`/`CommandsRun` as unordered
  sets, and a Thinking pane that is a formatted string. `turnTranscript` (Setting,
  **off** by default) writes one ordered JSONL file per Turn under
  `<DataDir>/transcripts/`. **Redaction is by construction:** the tool name selects
  one whitelisted argument field (`command`, `path`, `url`, `pattern`, `query`,
  `name`) and a tool the map does not know contributes a length only — a blacklist
  would have to be right about every future tool. **Model prose is a length, not a
  copy:** `answer`, `narration` and `reasoning` carry `bytes` only, which the live
  smoke proved necessary — asked to write a file containing a secret, the model
  quoted that secret back in its own answer, and the first smoke found it in the
  transcript. All three are already on the Message, so nothing is lost. Buffered in
  memory and flushed **once** at whichever exit the Turn takes (completed, stopped,
  budget-exhausted, failed); a per-record write would land on the thread holding
  the SSE stream open. Retention prunes by age then size on every write. Read back
  through `GET /api/transcript`, which is an ordinary token-gated `/api/` route.
  **`tool_result` records are never emitted and that is a finding, not an
  omission:** ShellPilot consumes tool results internally and exposes only a
  200-character `ResultPreview` that would itself carry file content, so the
  opening `meta` says `toolResults: not-observable`.
- **Nothing measured whether any of it worked.** `tests/live/eval/` is the parity
  eval harness: a 10-case corpus (`prompt.md` + `case.json` + `expect.json` per
  folder), a runner, deterministic graders, and comparison mode. **Fixture
  discipline is the part that decides whether the numbers mean anything:** the
  target repository is **cloned** to a throwaway folder and checked out at its
  pinned SHA, never checked out in place — a harness that restores a developer's
  working tree to make its own numbers reproducible has traded one kind of wrong
  for a worse one — and the runner asserts the SHA before it starts. Fresh Host
  Server, and therefore a fresh Engine Runspace, per case; prompt 07's
  environment-inheritance finding is recorded as a caveat on **every** result.
  Seven deterministic graders (`command_ran`, `tool_used`, `answer_contains`,
  `files_written`, `no_files_written`, `git_clean`, `instruction_followed`), each
  unit-tested **both ways** against committed fixture transcripts, because a
  grader that has never been seen to fail is not a grader; `llm_judge` is accepted
  and always advisory. The answer is read from the **Message**, not the
  transcript, which stores a length for prose. Efficiency is recorded, never
  graded. `build.yaml` lists only `tests/QA` and `tests/Unit`, so none of it runs
  in the gate.

## Verification

- `./build.ps1 -Tasks test` at each step: baseline **845/845**, then 860, 890,
  898, **931/931**, **1011/1011**, **1054/1054**, and **1095/1095**, 0 failed,
  9 tasks, 0 errors. **`-Tasks test` does not rebuild the module** — run
  `./build.ps1 -Tasks build` before any live smoke that imports
  `output/module/DeskPilot`, or it runs the previous build.
- `Invoke-ScriptAnalyzer` clean on every new file; the findings on
  `New-DpTurnParameter.ps1`, `Get-DpDefaultSettings.ps1` and `Merge-DpSettings.ps1`
  (`PSUseBOMForUnicodeEncodedFile`, `PSUseSingularNouns`,
  `PSUseShouldProcessForStateChangingFunctions`) are pre-existing name/encoding
  rules on untouched declarations. `Set-DpSearchTool` carries the same
  `PSUseShouldProcessForStateChangingFunctions` warning as the
  `Set-DpQuestionnaireTool` it was told to mirror. `node --check` clean.
- Three pre-existing tests were corrected rather than worked around: the cap
  default moved 25 → 50, and two Questionnaire tests asserted
  `ContainsKey('SystemPrompt') -eq $false` as a proxy for "no protocol" — now
  false because the budget sentence always adds a part, so they assert the
  absence of `ask_questions` itself, which is what they meant.
- **The search tools ARE live-smoked, and passed first time.** A real Turn on the
  Engine Runspace, prepared exactly as `Invoke-DpTurn` prepares it, asked "where
  is `Get-DpStreamFrame` defined, and where is it called from?" with the terminal
  left enabled so the model had a free choice. It called `search_text` **once**
  (`{"query":"Get-DpStreamFrame"}` → 43 matches), ran **zero** shell commands, and
  answered with the definition and every call site for 11,970 tokens / $0.052.
  The description did its job; no tightening was needed.
- **The edit tool is live-smoked, and passed first time too.** A real Turn was
  pointed at a throwaway git repository holding a real **630-line** source file
  and asked to add a three-line comment above one specific line, changing nothing
  else. It chose `search_files → search_text → read_file → replace_in_file`, never
  touched `write_file`, sent 253 characters of `newText` instead of the whole
  file, and `git diff --numstat` reported **`3  0`** — three lines added, none
  removed. 27,922 tokens / $0.062. That diff is the acceptance signal prompt 05
  named.
- **The transcript is live-smoked end to end, through the real Host Server.** A
  throwaway server on a free port and a throwaway git workspace; one multi-tool
  Turn told to write a file containing `SMOKE-SECRET-…`, read it back and run
  `git status --short`. Result: 8 records, `seq` 1-8 monotonic, timestamps
  non-decreasing, **all three** tool calls recorded (including `read_file` and
  `run_command`, which `Get-DpStreamFrame` drops), the secret present in the file
  on disk and **absent from the transcript** — as is the string `apiKey` and the
  absolute workspace path — and a second Turn with the Setting off wrote no file
  at all.
- **The eval harness is live-validated on one case, not on the corpus.** A real
  run of `find-definition-without-shell` against a cloned, SHA-pinned DeskPilot
  fixture passed all four graders in 15.3 s for $0.111, and the output files
  carry no token and no absolute user path.
- **Prompts 01-03 and 06 are still not live-smoked — that is the gap that
  matters.** No real Turn has streamed through the narration, instruction-push or
  workspace-context work. The acceptance signal for the instruction work is
  concrete and unmet: a real Turn's answer must open with the PRE-FLIGHT banner.
  Restart the whole DeskPilot process, not just the tab — the SPA hot-reloads
  from `source/web`, the module functions do not.

## Open, deliberately not done

- **The parity number itself.** The corpus exists and the harness works, but
  nobody has run it over the whole corpus at HEAD, nor against the pre-series
  commit. That delta is the number the entire series exists to produce, and it
  costs real credits twice over — the spend is the user's to authorise. One
  command plus a worktree build; see `tests/live/eval/README.md`.
- **No Settings toggle for `turnTranscript`.** Prompt 08 put the SPA out of
  scope, so the Setting is reachable through `PUT /api/settings` and
  `settings.json` only. A toggle is a deliberate follow-up, not an oversight.
- **07 is diagnosed** (below); its fix is unchosen and deliberately unwritten.
- **A search call does not appear on the Activity card, and that is deferred.**
  ShellPilot fills `result.FilesRead` only from its built-in `read_file`, so a
  User Tool never lands in the card's `Read` group; it does reach
  `activity.toolCalls`, which the SPA only renders as a bare count and only when
  no file rows exist. Listing every file a grep *touched* under "Read" would be a
  lie — the model received bounded snippets, not the files. The right fix is a
  per-tool-call row, which is exactly what prompt 08's Turn transcript
  introduces, so it waits for that rather than growing a special case here.
- **Prompt 06's live iteration counter was cut.** Honest counting needs an
  iteration signal that does not exist with Thinking off — the Engine only writes
  `=== iteration N ===` under `-ShowThinking`, and tool-call count is an *upper*
  bound on iterations, not the lower bound the prompt assumed. It needs the
  structured per-tool-call frame that prompt 08 introduces; shipping a mislabelled
  counter would have been worse than none.
- **F8, the reasoning summary, is a trade the user owns.** `$mode` is always
  `chat` because DeskPilot never passes `-DisableStreaming`, and
  `$requestReasoning` requires `responses` mode — so a reasoning *summary* is
  never requested and only providers volunteering `reasoning_text` deltas show
  anything. Buying it costs live answer streaming. Not implemented.
- **Prompt 07 is diagnosed, reproduced, and unfixed by request.** The Engine
  Runspace inherits the **launcher process's** `$env:PSModulePath` — environment
  variables are process-global, `[runspacefactory]::CreateRunspace()` sets none,
  and `Invoke-RunCommandTool` spawns its child `pwsh` without
  `-UseNewEnvironment`. `build.ps1` prepends `output/RequiredModules` and
  `output/module` to that variable *in the calling process*
  (`build.ps1:281`, `:449`), and `Start-DeskPilot.ps1` calls `build.ps1` with the
  call operator on first run, so DeskPilot's own Sampler dependencies follow the
  agent into every repository it works in. Reproduced exactly against
  `V:\Git\CopilotAtelier@d283c31` with one command, `Invoke-Pester -Path
  ./tests`, and only the module path varied: the repo's own vendored modules give
  **447/0/13**; DeskPilot's leaked in give **446/1/13**; Pester 6 with an
  otherwise default path gives **443/4/13** (the three `Changelog management`
  tests plus the module import) — the two harnesses' 1 and 4 failures, produced
  on demand. A second, unrelated defect fell out: `Invoke-RunCommandTool` builds
  its child argument list as a plain array, so **every double quote is stripped**
  from the command before it runs (`git … --pretty=format:"%h %s"` reaches git as
  two arguments) — the transcript records a command that never ran. No secret
  leaks: an all-scope, names-only scan found no credential-bearing environment
  variable, and the Engine's token lives in a file, not the environment. Options
  and trade-offs were reported; nothing was changed.

## Previous focus — edits are visible while they happen

**Edits are visible while they happen (`main`, 2026-08-11).** Asked for as "can
we have a file edit info and summary like in ghcp?", against a screenshot of VS
Code Copilot's per-edit lines and its `15 files changed +348 −88` bar. The
summary half already existed — the Changes card (FR-T10) has shipped counts,
**Keep** and **Undo** since the Git Workbench. What did not exist was the *live*
half: until `done`, the only thing that named the file being written was the
Thinking trace, so with **Show the model's thinking** off nothing named it at
all.

Three decisions carried it:

- **Drive it from the structured record, not the host trace.** ShellPilot emits
  a `ShpProgress` `ToolCall` record (`Name` + raw `Arguments`) before it runs the
  tool, and `Get-DpStreamFrame` was dropping it. A `write_file` call now becomes
  a `file` frame carrying the path. Reading the structured record is what makes
  the list independent of the Thinking Setting; parsing the arguments as JSON
  rather than pattern-matching them is what keeps a written file whose *content*
  contains `"path":` from naming the wrong file. A truncated or malformed
  argument string costs the drain loop one skipped frame.
- **Intent, not record — so no counts.** The announcement precedes the write, so
  there is nothing to measure and nothing to diff. Measuring anyway would mean a
  Git read per write on the very thread that keeps the SSE stream alive, which is
  the freeze `Invoke-DpGitCommand` exists to prevent. The rows carry a neutral
  ✎ glyph, no `+`/`−`, and no click target.
- **One element, two states.** The live rows and the reviewed card share
  `_refs.changes`, so the card *supersedes* the rows instead of appearing beside
  them. `renderChanges` therefore stopped clearing the element eagerly: it now
  seals the live rows (re-headed `N files edited`) whenever it cannot paint a
  card — no Project, no Git repository, or files already put back. That also
  makes a **stopped** Turn say what it wrote, which it never did before: a hard
  Stop persists an empty `activity`, and `Add-DpChangeEntry` only runs on the
  success path.

Nothing new is persisted, and the pending change set is untouched.

## Verification

- `tests/Unit/DeskPilot.Helpers.Tests.ps1` — +6 `Get-DpStreamFrame` cases (the
  path lifted out of a real `write_file` argument string; the frame emitted with
  and without `-ShowThinking`; and four silent cases — an empty path, a missing
  one, truncated JSON, and empty arguments). The existing "no frame for a
  ToolCall" case now says *which* tool calls stay silent.
- `tests/Unit/WebAssets.Tests.ps1` — +1 guard: both streaming paths carry the
  frame (send and regenerate/edit), one row per file rather than one per write,
  the card removing the live class, both seal branches, that `renderChanges` no
  longer wipes the element on entry, and the CSS that stops a live row looking
  clickable.
- Unit suite **835/835**; `node --check` clean; `Invoke-ScriptAnalyzer` reports
  nothing on `Get-DpStreamFrame.ps1`, and the only new findings anywhere are two
  more of the `PSAvoidUsingPositionalParameters` Information notices
  `WebAssets.Tests.ps1` already carries 37 of.
- **Not live-smoked**: no real Turn has streamed a `file` frame. Restart the
  whole DeskPilot process (not just the tab) — the SPA hot-reloads from
  `source/web`, the module functions do not.

## Previous focus — the Thinking pane is timed

**The Thinking pane is timed (`main`, 2026-08-11).** Reported as "there is a huge
delay between the iterations" — with no way to tell whether the wait was the
provider, a tool, or DeskPilot. `Format-DpThinkingTrace` now takes an optional
`-Timestamp` and prefixes `HH:mm:ss` to the two lines that *start* a section: the
iteration divider and the tool-call name. Prose is never stamped — a stamp per
streamed token is noise, not a measurement — and the stamp lands in a fixed
leading column, so the gap between two dividers reads straight off the pane.

The stamp comes from the record's own `TimeGenerated`, not `Get-Date`. The Turn
loop drains `Streams.Information` in 10 ms polled batches, so "now" would report
the drain rather than the write and would flatten exactly the gap the stamp
exists to expose. It also makes the measurement decide the open question: a
server-side stamp separates a slow Engine from a slow browser, and the browser is
a live suspect (`renderThinking` re-assigns `body.textContent` for the *whole*
accumulated trace on every `reasoning` frame, and a trace carrying written-file
bodies runs to hundreds of KB). `Format-DpThinkingTrace` stays pure: the
parameter is read through `$PSBoundParameters.ContainsKey`, so an unbound call is
still deterministic and the un-stamped shape is still tested.

### Diagnosis, no code: "I am missing the thinking output, we only see tool usage"

The screenshot runs **gpt-5-mini**, and there is no thinking to show. Evidence in
ShellPilot 0.3.1: `$requestReasoning = [bool]$ShowThinking -and ($mode -eq
'responses')`, and `$mode` only becomes `responses` when `-ShowThinking -and -not
$streamingEnabled`. DeskPilot never passes `-DisableStreaming`, so a text Turn is
always `chat` and a reasoning **summary is never requested**. On the chat stream
`Read-ShpChatStream` echoes reasoning only if the provider volunteers
`reasoning_text` / `reasoning_content` / `reasoning` deltas — Claude does, which
is why this looked fine until the Model changed; the gpt-5 family exposes its
reasoning through `/responses` only. Not a DeskPilot defect and not a leak
either: every echoed delta is wrapped in `` `e[3;90m ``, which `Get-DpStreamFrame`
matches, so reasoning can never arrive as answer text.

ShellPilot says so itself — Yellow, `(-ShowThinking: model '{0}' exposed no
reasoning trace on this backend…)` — but only **after** the loop ends, and
`finalizeAssistant` overwrites the pane with `m.reasoning` on `done`, so the one
explanation is destroyed at the moment it arrives. Buying the thinking back means
`-DisableStreaming`, which costs live answer streaming; that trade is the user's
to make, so nothing was changed.

### Diagnosis, no code: the mid-Turn `IDE token expired` 401

The refused "IDE token" is **not** the GitHub sign-in. `Get-ShpSessionToken`
exchanges the long-lived OAuth token for a short-lived session token carrying its
own `expires_at`; `Invoke-Shp` fetches it **once** per Turn, builds `$apiHeaders`
**once**, and reuses that hashtable for every tool iteration — so a Turn that
outlives its own token dies on whichever iteration crosses the expiry (the report
failed at **iteration 41**, well past the default 25). Nothing recovers:
`Invoke-ShpStreamRequest` is the one path not wrapped in `Invoke-ShpWithRetry`,
`Invoke-Shp`'s catch has no 401 branch, `Test-DpTransientEngineError` excludes 401
by design, and `Invoke-DpTurn`'s retry is gated on `emitted -eq 0` — so once text
has streamed the Turn cannot be retried without duplicating the answer.

The fix belongs in the **Engine** (re-resolve the token per iteration, force a
refresh on a 401 and retry that iteration, raise the 60 s safety margin), and
ShellPilot currently has uncommitted work in exactly those files, so neither
repository was changed. Details in `debugging-insights.md`.

## Verification

- `tests/Unit/DeskPilot.Helpers.Tests.ps1` — +4: the stamped divider, no-argument
  and single-argument tool call; prose left unstamped; the stream frame preferring
  `TimeGenerated` over the clock; the clock fallback when a record carries none.
  Two existing `Get-DpStreamFrame` cases now pin the stamped shape.
- Unit suite **828/828**; `Invoke-ScriptAnalyzer` clean on both changed files
  (the `PSUseBOMForUnicodeEncodedFile` warning is pre-existing — HEAD and the
  working copy start with the same bytes).
- **Not live-smoked**: no real Turn has streamed through the stamps. Restart the
  whole DeskPilot process (not just the tab) — the SPA hot-reloads from
  `source/web`, the module functions do not.

## Previous focus — the live Thinking survives a long answer

**The live Thinking survives a long answer (`main`, 2026-08-11).** Reported from
two screenshots: the trace and its tool calls stream into the Thinking pane, but
that pane sits *above* the answer inside its Message, so once the answer filled a
screen the pane was gone and the only thing still moving was the "Working…"
donut — which looks identical whether the agent is busy or hung.

Two halves, and the second is what makes the first usable:

- **Mirror the newest trace line where the answer cannot reach it.**
  `renderThinking` also feeds `setActivityStatus(lastTraceLine(text))`, which
  writes into `#activity-hint` above the composer — a footer element outside the
  scrolling thread, so no amount of answer can push it away. It is a `<button>`
  wired to `revealThinking`, so the line is also the way back to the pane it came
  from. `lastTraceLine` scans only the last 600 characters: it runs once per
  streamed reasoning frame and a laid-out trace runs to thousands of lines. The
  mirror inherits **Show the model's thinking** for free — with the Setting off
  `Get-DpStreamFrame` emits no `reasoning` frame at all, so the button stays
  `disabled` on its "Working…" text.
- **Stop fighting the reader's scroll.** Reading the pane mid-Turn was
  impossible anyway: every delta called `scrollThread()`, so scrolling up was
  undone by the next token. The 2026-08-09 note rejected a fix for a real reason
  — `.thread` sets `scroll-behavior: smooth`, so during an in-flight programmatic
  scroll `scrollTop` lags behind the newest token and *any distance test* reads
  that lag as "the reader scrolled away", killing auto-follow for the rest of the
  Turn. Direction is the signal distance cannot be: every programmatic scroll
  here moves **down**, so an upward move is the reader's. `wireThreadFollow`
  watches the thread's `scroll` event and flips `threadFollow` off on an upward
  move away from the bottom, back on at the bottom; `followThread` replaces
  `scrollThread` on the streaming paths only (`renderLive` ×2, `done`/`stopped`
  ×2, `renderRemoteLive`). Turn start, thread rebuild and an Ask-User card keep
  their unconditional scroll — those are deliberate jumps to something new.
  `revealThinking` clears `threadFollow` itself before scrolling, or the next
  streamed frame wins the race and pulls the thread straight back down.

Nothing server-side changed, and nothing new is persisted.

## Verification

- `tests/Unit/WebAssets.Tests.ps1` — +1 test (the mirrored line, its click
  target, the bounded tail scan, the one-line CSS, the direction test, the
  listener actually being wired in `wireGlobal`, `revealThinking` clearing the
  flag, and both `renderLive` bodies having left `scrollThread` behind); the
  existing Thinking guard now pins `followThread` in `renderThinking`.
- Unit suite **824/824**, `node --check` clean on `app.js`.
- **Not live-smoked**: no real Turn has streamed through it, so the mirrored line
  and the scroll hand-off have not been watched against a running agent. Restart
  the whole DeskPilot process (not just the tab) — the SPA hot-reloads from
  `source/web`, the module functions do not.

## Previous focus — the Thinking pane is readable

**The Thinking pane is readable (`main`, 2026-08-11).** Reported from a
screenshot: with **Show the model's thinking** on, the pane was a wall of text in
which a written file's line breaks appeared as literal `\n` and every Windows
path came out doubled. The cause is upstream and structural - ShellPilot writes a
tool call as `Write-Host ("-> {0}({1})" -f $tc.Name, $tc.Arguments)`, so the
provider's raw JSON argument string arrives on **one** host line.

Three decisions carried it:

- **Format on the server, not in the browser.** The tool call arrives as one
  atomic `Write-Host` record, so `Get-DpStreamFrame` is the only place that sees
  it whole and cheaply. The SPA appends `think += d.text` and repaints on every
  frame; re-parsing a growing trace client-side would pay that cost per frame.
  Formatting here also reaches Intercom's remote-Turn poll, which streams the same
  `reasoning` text to the window.
- **Only a complete line may be rewritten.** Reasoning prose streams token by
  token with `-NoNewline`; only the concatenation of many records is a whole
  thought, so a single token must pass through untouched. The rewrite is gated on
  the same `NoNewLine -eq $false` flag that already decides whether to re-attach a
  newline. `Format-DpThinkingTrace` also returns anything it does not recognise
  unchanged, so the gate is belt and braces.
- **Bound the pane instead of truncating the trace.** Laying a tool call out
  makes it many lines longer, and dropping the tail would hide exactly what the
  agent is about to write. `.thinking .disclosure-body` now carries
  `max-height: min(46vh, 420px)` with its own scroll, and `renderThinking` pins
  that scroll to the bottom - the thread scroll alone would leave the newest line
  out of sight now that the box no longer grows.

The persisted Message is unaffected: `Invoke-DpTurn` stores the Engine result's
`.Reasoning` (prose only, no tool trace), so this changes the live pane and
nothing on disk.

### Follow-up report: "the past Thinking box is truncated with `…`"

Diagnosed 2026-08-11, no code changed yet. The `…` is **not** ours and nothing
is hidden behind it - it is inside the reasoning text the provider delivers.
Evidence from the live store (`%LOCALAPPDATA%\DeskPilot\conversations.json`,
8 Messages carrying `reasoning`, 17 blocks): block lengths run 40-637 characters
with no cap, and 3 of the 17 blocks do **not** end in `…`, so no fixed-size
truncation is at work. Neither DeskPilot nor ShellPilot 0.3.1 appends `…` on any
reasoning path (grepped both). Claude returns *summarised* extended thinking; the
summariser ends a block mid-sentence, and the full chain of thought only exists
as the encrypted `reasoning_opaque` signature ShellPilot deliberately drops.

The one real defect next door: the past box is **poorer than the live one**. The
live pane carries iteration dividers and laid-out tool calls; `finalizeAssistant`
overwrites it with `m.reasoning` on `done`, and only that prose is persisted.
The user chose the narrow half of that: a **completed** Turn keeps today's
prose-only behaviour (persisting the streamed trace would carry whole
written-file bodies into `conversations.json`), while a **stopped** Turn no
longer loses its trace at all. `$turnState.reasoning` now accumulates every
`reasoning` frame in `$flush`, and the stopped Message carries it instead of
`$null` - a hard Stop discards the Engine result, so `result.Reasoning` never
arrives and the streamed frames are the only record left. No SPA change was
needed: `finalizeAssistant` already writes `m.reasoning` for a stopped Message.

## Verification

- `tests/Unit/DeskPilot.Helpers.Tests.ps1` - +9 `Format-DpThinkingTrace` cases
  (argument-per-line layout with real line breaks restored, short scalar inline
  vs long value blocked, a nested value re-serialised as indented JSON, the
  iteration divider keeping its leading blank line, a no-argument call, prose
  returned untouched, escapes still decoded when the JSON will not parse, and an
  empty or whitespace line passing straight through) and +2 `Get-DpStreamFrame`
  cases (a tool call laid out end to end; a streamed `-NoNewline` token never
  rewritten).
- `tests/Unit/WebAssets.Tests.ps1` - the Thinking guard now also pins the
  `max-height`, the `overflow: auto` and the inner scroll pin.
- Full Sampler build **831/831**, 9 tasks, 0 errors, 0 warnings, EXIT 0.
- **Not live-smoked**: no real Turn has streamed through the new layout. Restart
  the whole DeskPilot process (not just the tab) - the SPA hot-reloads from
  `source/web`, the module functions do not.

## Previous focus - Intercom can pick the Model

**Intercom can pick the Model (`main`, 2026-08-11).** Intercom could switch the
Conversation, the Agent and the Project, but not the Model - so the one setting
that decides *what* answers still needed a walk back to the machine. New
`/models`, `/model <n>` and `/model default`, an inline keyboard per listing, and
a `Model:` line in `/status`.

Three decisions carried it:

- **A Model switch writes two places, not one.** `Invoke-DpTurn` resolves the
  Conversation's own pin before the Settings default, and `New-DpConversation`
  pins whatever the default was when it was created. Writing only
  `settings.model` would therefore be a silent no-op for exactly the Conversation
  the operator is talking to, and the reply would name a Model the next
  instruction was never going to run on. `Switch-DpIntercomModel` sets the
  Setting *and* re-pins the bound Conversation; `/model default` clears both.
- **`/models` must never ask the Engine mid-Turn.** The Engine Runspace is
  single-threaded, so a second `[PowerShell]` on it would park the accept thread
  - the freeze `Invoke-DpGitCommand` exists to prevent. The listing reads the
  `/api/models` capability cache and only refills it from the Engine while no
  Turn is running; mid-Turn with an empty cache it says the list is not available
  and why. It also never *writes* that cache: the entries carry each Model's
  advertised reasoning efforts, and a half-shaped entry would reach the Turn.
- **One source for "which Model".** `Get-DpIntercomModelId` resolves the id for
  both `/status` and the `<- current` marker, so the two cannot disagree about
  the same fact. The button carries the listing's number against
  `Intercom.ModelIndex`, the way the Agent button does - a Model id is the
  provider's string, not one DeskPilot bounds, and one long id would cost the
  whole keyboard at the 64-byte `callback_data` cap.

The SPA follows: `syncSettingsFromIntercom` now watches `settings.model` too and,
when it moved, re-reads the open Conversation before repainting the composer
select - the select shows the *pin*, so a repaint from Settings alone would still
name the previous Model.

## Verification

- `tests/Unit/IntercomModel.Tests.ps1` - **24/24** under `Set-StrictMode -Version
  Latest`: parsing of all three verbs, numbering and the `current` marker with the
  Conversation pin outranking the Settings default, the Engine fallback on an
  empty cache, that the Engine is *not* asked while a Turn runs and that the
  cache is left untouched, the item bound, the listing and its index snapshot,
  switching by number and by tap, `/model default` clearing both writes, refusals
  for a non-number, an out-of-range number, a bare `/model` and a tap the index no
  longer backs, that no opted-in Project is required, the `/help` entries, and
  `/status` naming the resolved id rather than the Setting.
- `tests/Unit/WebAssets.Tests.ps1` - +1 guard that the settings re-read watches
  `model` and re-reads the Conversation before repainting the select.
- Full Sampler build **820/820**, 16 tasks, 0 errors, 0 warnings.
- **Not live-smoked**: no real Bot API call has been made for `/models`, and the
  Engine-fallback path has never run against a real sign-in. Restart the whole
  DeskPilot process (not just the tab) - the SPA hot-reloads from `source/web`,
  the module functions do not.

## Previous focus - Claude Opus 5 is DeskPilot's default Model

**Claude Opus 5 is DeskPilot's default Model (`main`, 2026-08-11).** DeskPilot
had no default of its own - `Get-DpDefaultSettings` sets `model = $null` and
`/api/models` handed back whatever `Get-ShpDefault` named, which is why the
window's Model chip read `claude-opus-4.6`.

Changing `Get-DpDefaultSettings` would not have worked. The persisted
`settings.json` carries `model: null`, and `Merge-DpSettings` assigns
`$merged.model = $null` for a key that is *present but null*, so the persisted
null beats any new default (checked against the live
`%LOCALAPPDATA%\DeskPilot\settings.json`). The default therefore belongs where
"default" is actually decided:

- **`$script:DeskPilot.PreferredModel = 'claude-opus-5'`**, and the
  `/api/models` route promotes it to `DefaultModel` **only while `Get-ShpModel`
  advertises it**. Otherwise the Engine's own default stands, so a hard-coded id
  this account cannot use never reaches a Turn. `DefaultModel` is seeded with the
  preference so an Intercom Turn that runs before the SPA ever calls the route
  already gets it.
- **`Invoke-DpTurn` now passes the resolved id.** It computed `$effectiveModelId`
  and then handed `New-DpTurnParameter` `-Model $Conversation.model`, so a
  Conversation pinning nothing ran on the *Engine's* default while DeskPilot
  reported its own.
- **The Settings "Default model" select tells the truth.** It marked an option
  `selected` only on `s.model`, so with nothing pinned the browser preselected
  whatever the Engine listed first — a field contradicting the Model the Turn
  would run on. It now falls back to `state.defaultModel`.

Picking a Model — in Settings or on one Conversation — still wins over all of
this.

## Verification

- `tests/Unit/ModelsRoute.Tests.ps1` — **5/5**: the preference reported as the
  default when advertised, the Engine's default when it is not, an empty Model
  list still answering 200, and source guards on the seed and on the resolved id
  reaching the Turn.
- `tests/Unit/WebAssets.Tests.ps1` — +1 guard on the Settings select fallback.
- Full Sampler build **795/795**, 16 tasks, 0 errors, 0 warnings, EXIT 0.
- **Not live-smoked**: the Engine's advertised list has not been read against a
  real sign-in, so whether this account is offered `claude-opus-5` is unproven.
  Restart the whole DeskPilot process (not just the tab) — the SPA hot-reloads
  from `source/web`, the module functions do not.

## Previous focus — Intercom can switch the agent and the project

**Intercom can switch the agent and the project, not just the conversation
(`ai/installer-decisions`, 2026-08-10).** `/chats` and `/chat <n>` shipped with
the original Intercom, which left the two settings that decide *how* and *where*
the agent works reachable only at the machine — exactly the thing Intercom exists
to avoid. New `/agents`, `/agent <n|none>`, `/projects`, `/project <n>` and
`/project new <path>`, each with an inline keyboard, plus an `Agent:` line in
`/status`.

Four decisions carried the design:

- **Selecting is navigation; creating is work.** Picking an Agent or a Project
  executes nothing — it decides the next Turn's `-SystemPrompt` and
  `workspaceFolder` — so neither needs an opted-in Project, the same split that
  keeps `/chats` usable when no Project is open. `/project new` writes to disk, so
  it requires one: a phone that cannot run anything cannot create folders either.
- **A remotely created Project is never remote-enabled.** If a remote message
  could opt a folder into remote control, the Project flag would be decorative —
  anyone holding the phone could point DeskPilot at any folder and run there. The
  reply says the flag is off and where to turn it on.
- **The Project button carries an id; the Agent button carries a number.** An
  Agent's id is its `*.agent.md` file name and has no length bound, and
  `Get-DpIntercomKeyboard` drops the *whole* keyboard when one button would
  exceed the 64-byte `callback_data` cap. `AgentIndex`/`ProjectIndex` snapshot
  the listing the way `ChatIndex` already does, and a number the index no longer
  backs is refused rather than resolved against whatever now sits there.
- **The window is no longer the only writer of Settings.** `refreshIntercom`
  now re-reads `/api/settings` while Intercom is on and repaints the Project and
  Agent chips when the selection changed. Without it the composer would keep
  naming a project and an agent the next Turn no longer uses.

Every switch reply states the remote-control status of the Project it moved to,
so the operator learns it before sending an instruction rather than from a
refusal.

## Verification

- `tests/Unit/IntercomNavigation.Tests.ps1` — **35/35**: parsing of all six
  verbs and their arguments (still rejected from a chat that is not
  allow-listed), the numbered listings and their index snapshots, switching by
  number and by tap, `/agent none`, refusals for a non-number and an out-of-range
  number, an agent button from a listing that has moved on, and creation —
  registering an existing folder, creating only the last segment, refusing a
  tree, a relative path, a drive root, a file, and the whole command when no
  Project has opted in; that the new Project is not remote-enabled; and that an
  already-registered path switches instead of erroring.
- `tests/Unit/WebAssets.Tests.ps1` — a structural guard that `refreshIntercom`
  calls the settings re-read, that it only runs while Intercom is on, and that it
  repaints both chips.
- Full Sampler build **789/789**, 16 tasks, 0 errors, 0 warnings, EXIT 0.

## Previous focus — Voice: German support, and read-aloud speaking Markdown punctuation

**Voice: German support, and read-aloud speaking Markdown punctuation (`main`,
2026-08-09, on `ai/voice-language`).** Two parts of the same report.

**(1) Language.** Both speech APIs were hard-wired to `navigator.language`, so
the spoken language was whatever the browser's UI language happened to be — a
German speaker on an English Windows got an English recogniser transcribing
nonsense and an English voice reading the answer back. New `ad_voicelang`
preference (auto / en-US / en-GB / de-DE / de-AT / de-CH) in **Settings → General
→ Voice language**, localStorage beside the theme and the send key, because it is
a per-machine input preference the Host Server gains nothing from knowing and it
shapes no Turn. Two traps: setting `SpeechSynthesisUtterance.lang` alone is not
enough — browsers keep reading with the default voice unless `voice` is assigned,
so `voiceFor(lang)` picks an exact match, then any voice sharing the base tag
(de-AT falls back to a de-DE voice), then nothing; and Chrome populates
`speechSynthesis.getVoices()` asynchronously and returns `[]` until it lands, so
`initVoice` asks for it once at startup. An unrecognised stored value falls back
to `auto` rather than handing the browser a tag it will reject.

**(2) Punctuation.** `speakText` only stripped code fences, so an answer was
spoken verbatim: "hash hash Setup", "star star", a table read as a run of
"vertical bar". New `markdownToSpeech(src)` in `markdown.js` — deliberately
beside `renderMarkdown` and mirroring its line grammar, so what the renderer
treats as syntax is exactly what is never spoken and the two cannot drift.
Headings, list items, blockquotes and table rows become sentences with a full
stop (without one the reader runs them together), links are read by label, rules
are dropped, and a code block is announced as "Code block." rather than spelled
out. No spoken label was invented for task-list checkboxes: the marker is simply
dropped, because "Done:"/"To do:" would be English words injected into German
speech.

Guards in `WebAssets.Tests.ps1`: the language helpers run under `node`'s `vm`
with a faked `localStorage`/`navigator`/`speechSynthesis`; `markdownToSpeech` is
imported as ESM and asserted to drop every syntax character while keeping every
label. Textual assertions keep both speech APIs off `navigator.language` and keep
`speakText` on the stripper.

**(3) Quality.** Reported as "sounds like from the last decade, not fluent, not
well emphasized; 1945 is read as a number, not a year". Root cause was voice
*selection*, not the API: `voiceFor` took the first language match, and Windows
lists its 2010-era SAPI `… Desktop` voices first (this machine: Hedda Desktop
before Katja). New `speech.js` — `pickVoice(voices, lang, preferredName)` scores
exact language tag first (an explicit en-GB must never be answered in en-US),
then quality: `Natural`/`Online`/`Neural` +4, a Google voice +3,
`localService === false` +2, `Desktop` −3. A **Voice** picker in Settings lists
every voice for the chosen language and overrides the ranking; the saved name is
dropped when the language changes, because a German voice cannot read English.
Years: the Web Speech API has **no SSML**, so a date cannot be marked up —
`numbersToSpeech(text, lang)` rewrites the digits into words instead, but only
after a year cue word (`in`, `since`, `im`, `seit`, `Jahr`…) and only inside
1100–2099, so `8080`, `ran 1945 tests` and `in 3000 ports` are untouched. Only
`en` and `de` are spelled out; any other language is returned unchanged rather
than mangled.

## Previous focus — the Thinking box arrived collapsed and below the fold

Two defects in one report. (1) `buildAssistantEl` created the
`<details>` without `open`, so "Show the model's thinking" only unhid a box the
user still had to click on every answer — the Setting is a request for
visibility, so it now sets `thinking.open` from `state.settings.showThinking` at
build time (the node is built after the Setting is read, so nothing has to
re-render when it is toggled). (2) `_runTurn` scrolls once, right after appending
the still-empty assistant bubble; the `reasoning` handler then unhid and grew the
box without scrolling, so a long think unfolded below the fold and read as a
stalled turn. The answer stream never showed this because `renderLive` already
scrolls on every delta.

Both live reasoning handlers (`_runTurn`, `_streamRerun`) and the Intercom live
bubble now go through one `renderThinking(wrap, text)` helper that unhides,
writes and scrolls together, so a future call site cannot lose the scroll again.
`finalizeAssistant` deliberately stays inline: it runs once per message during a
full `renderThread`, which scrolls once at the end.

Structural guard in `WebAssets.Tests.ps1` asserts the `open` assignment, that the
helper scrolls, and that the number of `renderThinking(wrap, think)` calls equals
the number of live `reasoning:` handlers — the last one is what fails if someone
adds a third streaming path and inlines the DOM write.

## Previous focus — the file viewer froze the window on a CRLF Markdown file

Reported against `C:\Git\Kinesiologie\vorlagen\kontakt-email-vorlage.md`;
other files opened fine. Not the Host Server — `Get-DpFileContent` and
`Write-DpResponse` are correct. `renderMarkdown` in `web/assets/markdown.js` never
normalised line endings, and its heading branch is `/^(#{1,3})\s+(.*)$/`: without
the `m` flag `$` only matches end-of-input and `.` cannot cross a `\r`, so the
pattern fails on `## Heading\r` while the paragraph gatherer's exclusion
`/^(#{1,3})\s/` still matches. The gatherer therefore consumed nothing, `i` never
advanced, and the loop spun — freezing the JS thread, which is why the modal was
still painting "Loading…".

The fix normalises `\r\n?` to `\n` before escaping, and the paragraph branch now
consumes the current line when no other branch claimed it, so no future regex
drift can stall the renderer again. Node-based regression test in
`WebAssets.Tests.ps1`, run out of process under a timeout because the failure mode
is a hang. Unit suite **739/739**.

Separately observed, not fixed: `escapeHtml` runs before the line parse, so `>`
is already `&gt;` and the blockquote branch is unreachable — blockquotes have
never rendered anywhere in the SPA.

## Previous focus — Linux-only `Checkpoint.Tests.ps1` failures

`Checkpoint.Tests.ps1` was green on Windows and failed 4 in CI. The four
failures all reduce to one fact: `Restore-DpCheckpoint` found no files inside
the Project, because the test built its Project as `'C:\proj'` and its written
files as `"$Root\src\one.ps1"`. On Linux a backslash is an ordinary filename
character, so neither is a path under that root; the `Join-Path` branch then
normalises `\` to `/` through the Unix FileSystem provider while `$rootTrim`
(from `[IO.Path]::GetFullPath`) keeps them, and the boundary check rejects
everything.

Test data only: the root is now platform-native and child paths come from
`[System.IO.Path]::Combine`. The production code was already correct on both
platforms, so nothing under `source/` changed and no assertion was weakened.
Windows suite **748/748**, build EXIT 0; Linux is for CI to confirm.

## Previous focus — green build restored on `main`

`./build.ps1 -Tasks build,test` was failing 2 of 748. The tests were right and
the code was wrong: merge
**665b260** (Intercom PR #4) carried the worktree revert of **42641d7** — the
2026-08-06 "undo doesn't work" fix — into `main` while keeping that commit's
tests, so the suite reported its own regression.

Only the *call sites* were lost; `reconcileDiffFiles` survived in `diff.js`. The
`gitRestore` route stopped clearing a restored file from the pending change set,
and `app.js` lost the import, `refreshDiffViewer` and its two callers. Restored
verbatim from 42641d7 rather than rewritten, along with the CHANGELOG entry and
the two `systemPatterns` entries that were reverted with it. **No test was
changed.** Full suite **748/748**, build EXIT 0.

The *Known repository state* note below is therefore resolved: the revert is
gone from `main`.

## Previous focus — Intercom inline keyboards

**Tap instead of type (`ai/intercom`, 2026-08-09).**
Parity with BotFather: a closed choice should be a button, not a number to read
and retype at a bus stop. Buttons ride under an Ask-User question and the
`/chats` listing; the written form always still works, so nothing depends on them
rendering.

The three constraints that shaped the code:

- **`callback_data` is capped at 64 bytes**, so it carries a prefix, a nonce and
  an index rather than the label. `Get-DpIntercomKeyboard` drops the *whole*
  keyboard when a button would exceed it — a button that fails silently when
  tapped is worse than no button.
- **Old buttons never disappear.** Telegram leaves them on screen indefinitely, so
  an option tap carries `PendingQuestion.token` and is refused when it does not
  match. Without that, a tap on a question answered hours ago would answer
  whatever is waiting now.
- **A tap must be acknowledged**, or Telegram shows the button spinning forever.
  `answerCallbackQuery` is queued ahead of the reply and bypasses the hourly cap;
  the pump gained a general `operation`/`payload` record so a bare Bot API call
  rides the same single-send queue and nothing waits on the accept thread.

Buttons are offered **only** for a single-question, single-select Ask-User. A
multi-select keeps the written-reply flow: one tap cannot say "these two", and a
keyboard that silently drops the second choice is worse than none.

Before this, **Checkpoints**: the pre-Turn snapshot DeskPilot already took, made
addressable from the transcript as a **Restore Checkpoint** divider, restorable
from the window and from Intercom's `/undo`. The restore is bounded to the paths
in `activity.filesWritten` rather than a folder-wide checkout, so hand edits made
in between survive — the boundary the pending change set exists to draw (spec
090). `Get-DpCheckpointSha` stops `Remove-DpChangeEntry` garbage-collecting a
snapshot a Message still references.

## Verification

- `tests/Unit/IntercomKeyboard.Tests.ps1` — **19/19**: layout and per-row packing,
  the 64-byte drop, label truncation, a tap parsed as its own kind, a tap from a
  chat that is not allow-listed rejected before its data is read, the
  `answerCallbackQuery` queued first, the *label* submitted rather than the index,
  a stale nonce and an out-of-range index both refused, chat switching, and the
  keyboard offered only for a single-select single question.
- `tests/Unit/Checkpoint.Tests.ps1` — **21/21** under `Set-StrictMode -Version
  Latest`: sha collection and per-Project filtering, truncation and the returned
  prompt, the bounded file set handed to the undo, pending-change clearing,
  refusal of a vanished or assistant Message, the no-snapshot and no-Project
  paths, `-SkipFiles`, `-Preview` changing nothing, an intact Conversation when
  the git restore fails, and `/undo`'s preview-then-confirm, its refusals (Turn
  running, bound Conversation gone, archived, no Checkpoint) and that it takes
  the **most recent** Checkpoint.
- A ref-protection guard in `tests/Unit/DeskPilot.Helpers.Tests.ps1`: Keeping a
  change does not delete a snapshot a Checkpoint still restores from (the sibling
  test proves the same inputs *do* delete it without one).
- SPA structural guards in `tests/Unit/WebAssets.Tests.ps1`: the divider is gated
  on `m.checkpoint.sha`, restoring always confirms, the prompt is put back in the
  composer, and `refreshCurrentConversation` calls `syncCheckpointDividers`.
- Full suite **748/748** after the revert was undone; before that, 735/737 with
  the two failures caused by it.
- PSScriptAnalyzer clean on every new source file; `./build.ps1 -Tasks build,test`
  EXIT 0.
- **Not yet live-smoked.** Restoring rewrites files on disk, and the keyboard path
  has never touched a real Bot API; exercise both against a real Project and a
  real bot before trusting them.

## Known repository state — not mine

`.memory-bank/progress.md`, `.memory-bank/systemPatterns.md`, `CHANGELOG.md` and
the `gitRestore` case in `Invoke-DpRouteHandler.ps1` carried a wholesale revert
of the 2026-08-06 "undo doesn't work" fix — uncommitted at first, then carried
into `ai/intercom` and merged to `main` as **665b260**. **Resolved on
2026-08-09** by restoring 42641d7's hunks verbatim. Nothing outstanding here.

## Next step

Restart DeskPilot — the whole process, not just the browser tab: the SPA
hot-reloads from `source/web` but the module functions are already in memory,
which is why the first Checkpoint attempt showed no divider. Then live-smoke
against a real bot: an Ask-User question with options should arrive with tappable
buttons that answer it in one tap, `/chats` should switch on a tap, and a tap on
an older question's buttons should be refused rather than misrouted. Then a
Checkpoint restore from both surfaces — confirm the divider appears on the turn
just run, the prompt returns to the composer, a file the agent wrote is put back
and one it created is deleted, a hand edit to an untouched file survives, and
`/undo` previews accurate numbers before `/undo confirm` acts. Also live-smoke
the restored undo path: confirming an undo in the diff viewer should drop the
file from the modal's list rather than leave it there with a second Undo button.

## Previous focus — Intercom

**Intercom — remote control from a phone (spec 110).** Telegram bot, long-polling
only, no inbound port and no relay. `Update-DpIntercomState` never waits on the
accept thread — every call is an `HttpClient` `Task` started on one tick and
reaped on a later one — and it runs from the idle tick *and* from
`Invoke-DpPendingRequest`, because the moment Intercom matters most is mid-Turn.
Only the idle-tick caller passes `-AllowTurn`, so a command arriving mid-Turn is
queued rather than re-entering `Invoke-DpTurn`. Silence was made legible by
*editing* one status message on a timer (Telegram does not notify on an edit) that
always states its next check-in deadline, so a dead machine freezes it in the past.
Before that: an open modal re-reading the change set, and an unpriced Model
reading as `$0.0000`.
