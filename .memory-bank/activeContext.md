---
schema-version: 1
status: accepted
owner: shared
last-verified: 2026-08-08
source: repository evidence
---

# Active Context

## Current focus

**Intercom — remote control from a phone (`ai/intercom`, 2026-08-08).** Spec 110,
signed off after a `grill-me` interview. The operator runs long jobs and cannot
reach the machine over RDP while travelling; a job blocked on a question used to
idle until they got back.

It lives in **DeskPilot**, not ShellPilot and not a Skill: every concept it gates
on — Project, Permission, Conversation, Settings — is a DeskPilot concept, and
the Engine needs no change. The Atelier's share is check-in *discipline* as an
extension to the `long-running-job-monitor` Skill, which is behaviour, not
transport, and is not built here.

The two decisions that shaped the code:

- **Nothing waits on the accept thread.** `Update-DpIntercomState` starts an
  `HttpClient` `Task` on one tick and reaps it on a later one. It runs from the
  idle tick *and* from `Invoke-DpPendingRequest`, because the moment Intercom
  matters most is mid-Turn — and only the idle-tick caller passes `-AllowTurn`,
  so a command that arrives mid-Turn is queued rather than re-entering
  `Invoke-DpTurn`.
- **Silence had to be made legible.** With no relay, a dead machine cannot report
  itself. One status message is *edited* on a timer (Telegram does not notify on
  an edit, so it costs nothing) and always states its next check-in deadline. When
  the machine dies the message freezes with a time in the past.

## Verification

- `tests/Unit/Intercom.Tests.ps1` — **50/50**: the allow-list runs before any text
  is parsed, a reply to the question message is the only accepted answer, the
  command grammar, message splitting and bounds, the per-Project gate, Settings
  validation, token redaction, the rate cap (and the status message's exemption
  from it), the secret store, and a guard that the pump never starts a Turn
  without `-AllowTurn`.
- Full suite **613/615**. The two failures are a **pre-existing revert in the
  working tree**, not Intercom — see *Known worktree state* below.
- PSScriptAnalyzer clean on every new file.
- Live smoke against a running Host Server: `/api/intercom` is 401 without a
  session token, a malformed bot token is 400, an out-of-range setting is 400, and
  the stored token appears in no response, not in `settings.json`, and not in
  clear text in `intercom.secret`.

## Known worktree state — not mine

`.memory-bank/progress.md`, `.memory-bank/systemPatterns.md`, `CHANGELOG.md` and
the `gitRestore` case in `Invoke-DpRouteHandler.ps1` carried **uncommitted
deletions before this session started**: a wholesale revert of the 2026-08-06
"undo doesn't work" fix. `refreshDiffViewer` is gone from `app.js` and the
`Remove-DpChangeEntry` block is gone from the `gitRestore` route, so those two
tests fail. HEAD contains the fix and passes; the working tree does not. This was
left untouched on purpose — it is unrelated in-progress work. Decide whether to
restore it or discard it before the next release.

## Next step

Live-smoke Intercom against a real bot end to end: create a bot in BotFather,
follow `docs/intercom-getting-started.md`, and confirm the four flows — a
forwarded question answered by reply, a cold-start prompt, `/stop` mid-Turn, and
the status message's check-in time advancing. Then resolve the worktree revert
above.

## Previous focus

An open modal re-reading the change set (the diff viewer keeping a stale file
list after Keep/Undo), and before that an unpriced Model reading as `$0.0000`.
