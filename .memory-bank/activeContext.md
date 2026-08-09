---
schema-version: 1
status: accepted
owner: shared
last-verified: 2026-08-09
source: repository evidence
---

# Active Context

## Current focus

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
