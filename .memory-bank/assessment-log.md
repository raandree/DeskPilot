---
schema-version: 1
status: accepted
owner: security-reviewer
last-verified: 2026-09-02
source: repository evidence
---

# Assessment log

Episodic record of security assessments: date, scope, verdict, top findings,
remediation status. Newest first. Retention: two years, then archive to a dated
topic file.

## 2026-09-02 — Intercom group chat (`ee0bdd7`, branch `ai/intercom-group-chat`)

**Scope:** the 26-file change set that allow-lists a shared Telegram group
alongside the operator's own chat, routes replies per chat, scopes the answer
nonce, fixes the false stall warning, and strips the bot's addressing mention.

**Verdict: CONDITIONAL.** The commit is safe to hold on the branch because the
feature is default-off behind two switches. It is **not** safe to switch
`allowGroupChat` on until FIND-001 and FIND-002 are closed.

| ID | Severity | CVSS | Finding | Status |
| --- | --- | --- | --- | --- |
| FIND-001 | High | 8.1 | `/undo` and `/delete` never call `Test-DpIntercomProject`, so any group member can rewrite files on disk and destroy Conversations in any Project, opted in or not | **closed** |
| FIND-002 | High | 7.1 | The per-Project `intercom` flag cannot express "me but not the group"; ticking the group box silently extends every already-opted-in Project, including `git push`, with no re-confirmation | **closed** |
| FIND-003 | Medium | 5.3 | The audit log records no sender for an accepted command, so a now-multi-user feature cannot attribute an action to a person. `fromName`/`chatId` are computed by `ConvertFrom-DpIntercomUpdate` and discarded | **closed** |
| FIND-004 | Medium | 4.3 | Work bound to a chat that was just de-authorised is still delivered there: the `chatId` PUT branch clears no queued prompt, and neither branch clears an in-flight `Download` | **closed** |
| FIND-005 | Low | 2.6 | No allow-list re-validation at enqueue time. `ReplyChatId` is stamped from an attacker-controlled `$command.chatId` *before* the rejection check; only an early `return` keeps "never answer a caller you just rejected" true | **closed** |
| FIND-006 | Low | — | `getMe` failure is swallowed with no log, unlike every other Intercom error path | **closed** |
| FIND-007 | Nit | — | `^-\d{1,20}$` admits ids wider than int64; mirrors the pre-existing `chatId` pattern | **closed** |

### Remediation, 2026-09-02 (same day)

Verdict moves **CONDITIONAL → CLEARED for the branch**. `allowGroupChat` may now be
switched on. It was not switched on during this work, and nothing was pushed.

- **FIND-001 — closed.** `/undo` and `/delete` are gated on the *primary chat*,
  not on the Project flag. The Project flag answers "where may work happen"; these
  two act on the operator's own history and Checkpoints, so it was the wrong gate
  and gating them on it would still have left them reachable by any group member
  in any opted-in Project. `/undo`'s gate lives inside `Restore-DpIntercomCheckpoint`
  behind a new `-OriginChatId`, not only at the dispatcher, so a second caller
  added later cannot reach the file rewrite by skipping the command switch.
  `/archive` is deliberately left open: `/unarchive` undoes it, it writes nothing
  to disk, and `/chats` already exposes the list to the group. Recorded in spec
  110's command table as a third answer — "the operator's own chat only" — with
  the reasoning above it rewritten, since it had justified the split purely in
  terms of "runs work in a Project".
- **FIND-002 — closed, operator chose A + B.** A per-Project `intercomGroup` flag
  (default `false`, even for a Project the operator's own phone already drives),
  checked in `Test-DpIntercomProject` via a new `-OriginChatId` and threaded from
  all three call sites. **Plus** a server-side disclosure: `PUT /api/intercom`
  refuses to switch `allowGroupChat` on with **409 `confirm_group_projects`** and
  the names of the Projects it would cover, until the same request carries
  `confirmGroupProjects: true`. The flag is the control; the 409 is what stops the
  control being granted unread. This narrows the trifecta's second leg to a set
  the operator names rather than breaking it — inside a shared Project all three
  legs remain — and A3 is rewritten to say exactly that.
- **FIND-004 + FIND-005 — closed by one structural fix.** `Send-DpIntercomMessage`
  now resolves its target and re-validates it against the live allow-list through
  the new `Test-DpIntercomChat`, falling back to the operator's chat and recording
  a dropped `misrouted` message. The clearing logic was kept and completed as
  defence in depth: the `chatId` branch now drops the queued prompt and image, and
  both branches abandon an in-flight `Download` through the new
  `Clear-DpIntercomDownload`.
- **FIND-003 — closed.** `Add-DpIntercomLog` takes optional `-ChatId` and `-From`,
  populated on every inbound call in `Invoke-DpIntercomCommand` (accepted,
  rejected, ignored, edited). They flow out through `Get-DpIntercomPayload` and are
  rendered in the Status panel row, bounded to 60 characters and passed through
  `Hide-DpIntercomSecret` like the detail. Attribution, not authentication: the
  name is whatever Telegram reported.
- **FIND-006 — closed.** Both `getMe` paths — the start and the reap — now bump the
  error counter and log `identity-error` through `Hide-DpIntercomSecret`.
  `LastError` is deliberately *not* set: it drives the panel to a red 'error'
  status, and a failed identity lookup only costs the mention strip.
- **FIND-007 — closed, and `chatId` tightened with it.** Both patterns are now
  `\d{1,19}` plus a `[long]::TryParse` range check, because a Telegram chat id is
  an int64 and the digit count was never the real bound. Tightened together so a
  value one key accepts the other cannot reject. No changelog entry: Telegram
  cannot issue a 20-digit id, so nothing a user could have configured changed.

**A StrictMode defect was found and fixed during remediation, not by the tests
that were written for it.** `Test-DpIntercomChat` first read `$Settings.intercom`
and `$intercom.allowGroupChat` directly. Under `Set-StrictMode -Version Latest` a
missing key throws, and the function now sits on `Send-DpIntercomMessage` — the
path that reports a finished job. Ten existing tests went red with
`PropertyNotFoundException`, which is the same failure the codebase already
learned twice (`Invoke-DpIntercomTurn`, then the addressing fields). **Every
optional read on that path must go through `Get-DpPropertyValue`; a fix that adds
a new caller to a shared path inherits that path's failure mode.** Two existing
fixtures were also corrected rather than worked around: they asserted group
routing without allow-listing the group, which the re-validation now — correctly —
refuses.

**Evidence.** Red-first was proved, not assumed: the 40 new tests in
`tests/Unit/IntercomAuthority.Tests.ps1` were run against a detached worktree at
`54baab6` (the unfixed tip, which still carried all seven findings) and came back
**11 passed / 29 failed**. The 11 that passed are exactly the positive
counterparts — `/delete` for the operator, `/archive` from the group, the status
message pinned to the operator's chat, a valid id accepted — which is what proves
the refusals are not passing because the branch is unreachable. Full Sampler gate
`build, test` green. PSScriptAnalyzer: no new findings across all 13 changed
production files (two pre-existing findings confirmed against the same baseline).
`node --check` clean on `app.js`.

FIND-004 and FIND-005 share one structural fix: resolve and **re-validate** the
target chat against the live allow-list inside `Send-DpIntercomMessage`, instead
of enumerating every place that has to clear stale routing state.

**Gap in this assessment, found in use the same day.** The review reasoned about
`ReplyChatId` as ambient state (FIND-005) but never asked whether the pump that
owns it is re-entrant. It is: `Update-DpIntercomState` → `Invoke-DpIntercomTurn` →
`Invoke-DpTurn` → `Invoke-DpPendingRequest` → `Update-DpIntercomState`. Nested
ticks cleared the target to `$null` in their `finally`, so a group Turn's
acknowledgement arrived in the group and its question arrived privately, and the
answer nonce was recorded against the wrong chat. Fixed by save-and-restore at all
three override sites, with a red-first regression pair. **Lesson for the next
review: when a finding is about ambient or dynamically scoped state, check the
call graph for re-entrancy before rating it, because the severity depends on it.**
The re-validation recommended above would have contained the blast radius but not
prevented the misrouting.

**Lethal trifecta:** all three legs are present and leg 2 widened materially.
Private data = the Project's files and git credentials; untrusted content = repo
contents the agent reads *plus* messages from an externally-managed group
membership; outbound channel = Telegram replies and `git push`. Recorded as
accepted risk A3 in spec 110 by explicit operator decision, mitigated only by
default-off, two switches, and stated consequences. The trifecta is **not**
broken. What would break it: a read-only mode for group-originated Turns, or a
separate per-Project flag so a group can only reach Projects chosen for it
(which is also FIND-002's fix).

**Verified clean:** token never touched by the new code and still absent from
every response; `Hide-DpIntercomSecret` still on all pump error paths;
`escapeHtml` on both new DOM writes; negative-id enforcement and the
`groupChatId != chatId` cross-check correctly placed after the key loop, where
hashtable ordering cannot defeat it; the chat-scoped answer nonce is a genuine
correctness fix, not just a hardening; the live status message is correctly
pinned to the operator's chat.

**Compliance:** PSScriptAnalyzer no new findings. One deviation found and fixed
during review — `CHANGELOG.md` had `### Fixed` before `### Added` and a duplicate
`### Added` under one release heading, against `changelog.instructions.md` and
Keep a Changelog ordering. No instruction file exists for `**/*.js`, so the SPA
edits were reviewed against OWASP guidance only; see the escalation note in
`activeContext.md`.
