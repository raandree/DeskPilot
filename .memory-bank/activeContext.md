---
schema-version: 1
status: accepted
owner: shared
last-verified: 2026-08-11
source: repository evidence
---

# Active Context

## Current focus

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
