---
schema-version: 1
status: accepted
owner: security-reviewer
last-verified: 2026-09-07
source: repository evidence
---

# Assessment log

Episodic record of security assessments: date, scope, verdict, top findings,
remediation status. Newest first. Retention: two years, then archive to a dated
topic file.

## 2026-09-08 — Intercom mention-only group intake (`38e4e99`)

**Scope:** the opt-in `intercom.requireGroupMention` gate on
`ai/intercom-group-mentions` — six source files, two test files, the getting-started
guide, and the changelog.

**Verdict: CONDITIONAL.** No Blocker, no High, and no security regression. The
change is a net reduction of the untrusted-content surface: it only ever admits
fewer Telegram updates, runs after the chat allow-list, fails closed when the bot
username is unknown, and grants no Permission. It is blocked from `main` only by
FIND-011 and the specification gap in FIND-012.

| ID | Severity | CVSS | Finding | Status |
| --- | --- | --- | --- | --- |
| FIND-011 | Major | — | With the gate on, a Telegram reply to the forwarded question is dropped in an allow-listed group. The Turn stays blocked until `questionTimeoutMinutes` expires, with no reply to the sender | **open** |
| FIND-012 | Minor | — | Specification 110's Settings table and its *Addressing a group message* row do not carry `requireGroupMention`; the spec is the Intercom contract | **open** |
| FIND-013 | Minor | — | `tests/Unit/intercom-ui.test.mjs` runs in no automated gate: Pester discovers only `*.Tests.ps1`, and no build task or CI step invokes `node --test` | **open** |
| FIND-014 | Minor | — | `New-DpSupportBundleRecord` reports `groupEnabled`/`groupCount` but not `requireGroupMention`, so a bundle cannot explain "Intercom ignores my group" | **open** |
| FIND-015 | Minor | — | When `getMe` fails, the `identity-error` line still says only a mention will stay in the prompt; with the gate on the real consequence is that no group Message is accepted for the session, and there is no retry | **open** |
| FIND-016 | Low | — | Every un-addressed group Message adds an entry to the 200-item audit ring, evicting genuine rejections and errors in exactly the busy group the option targets | **open** |

### Evidence

- Full Sampler gate on the reviewed tree: **2,537 passed, 0 failed, 18 skipped**
  (13 child-execution, five existing browser Unicode), 17 tasks, zero warnings.
- FIND-011 proven by direct execution of the reviewed parser: one identical
  reply-to-question update returns `answer` with the option off and `ignore`
  with it on, reason `Group Message did not mention this Intercom.`
- A suspected null-reference in the command-target gate was **discarded as a
  false positive**: with an empty and a `$null` `BotUsername`, `/status@Otherbot`
  in a group returns `ignore` without throwing, because the first gate returns
  before that expression is reached.
- Entity-based matching was probed for bypasses: a `code`-typed entity, a longer
  username, a foreign `bot_command`, a missing entity, and malformed or
  overflowing offsets all fail closed. Offsets are UTF-16, matching .NET.
- No new lethal-trifecta leg. Layer 6 screening found no LLM01/02/05/06/08
  regression; the mention is addressing, never authorization.

### Notes

Remediate FIND-011 by admitting a reply that matches the pending question's
message id in the same chat — that admits nothing the allow-list does not
already admit — or accept it explicitly and say so in the guide. `threat-model.md`
and `security-playbooks.md` were deliberately not created: specification 050 and
110 already hold that content, and duplicating repository source into the Memory
Bank is a documented red flag.

## 2026-09-07 — Staged `main` merge candidate (`64b8b16` + `MERGE_HEAD 7631b10`)

**Scope:** the uncommitted 97-file merge of `ai/turn-wide-terminal-approvals`
into `main` — single-child V3, ordinary Terminal Turn grants, and their docs.
75 code files, 30 test files, 19 Markdown files.

**Verdict: REQUEST CHANGES.** No Blocker or Major was found in the changed V3
containment or Turn-grant logic itself, and the merged gate is green. The merge
is blocked by FIND-008, a pre-existing defect in a shared approval helper this
candidate modifies.

| ID | Severity | CVSS | Finding | Status |
| --- | --- | --- | --- | --- |
| FIND-008 | High | 7.5 | `New-DpApprovalRequest` truncates commands/URLs at 2,000 characters and form values at 500, and derives the form fingerprint from the truncated copy — while the executors dispatch the full value. An approval can authorize content it never displayed | **closed** |
| FIND-009 | Minor | — | Child stderr drain tasks (`_providerErrors`, `_errors`) are assigned and never observed, so a 16 KiB overflow surfaces as a deadline timeout with a misleading reason instead of its real cause | **open** |
| FIND-010 | Minor | — | The new `stopTurn` active-child branch has no direct route test; `ChildRoutes.Tests.ps1` covers only `stopChildRun` | **open** |

### Evidence

- Full merged gate: **2,506 passed, 0 failed, 5 existing browser skips, 0 unrun**;
  16 tasks, zero errors/warnings. Coverage was disabled for this run.
- `git diff --cached --check` passed; no unresolved paths; no secret-like paths.
- FIND-008 proven twice with inert fixtures, no real command and no browser:
  a 5,002-character command displayed 2,032 characters and forwarded 5,002; two
  distinct 519-character form values produced identical displayed values **and**
  identical fingerprints.
- No owned child or Isolated Terminal containers remained afterwards.

### Notes

FIND-008 predates this candidate — every truncation branch exists at `64b8b16` —
but it contradicts the exact-value contract in specification 040 and the
changelog, so it is reported against the merge rather than deferred. Remediate by
refusing overlong commands before approval, rendering bounded browser values
completely or refusing them, and fingerprinting the complete normalized action.
The refreshed built-runtime V3 proof had not yet run against this candidate.

### Remediation, 2026-09-07 (same day)

Verdict moves **REQUEST CHANGES → CLEARED for the merge**. The merge is committed
as `e109c55`; the fix follows it on `main`.

- **FIND-008 — closed, test-first.** Nothing in an approval card is shortened
  now. `New-DpApprovalRequest` renders the command, the whole URL including its
  query string, and every form value in full, and the fingerprint is derived from
  those complete values. Content above what the card can show is refused rather
  than displayed in part: 2,000 characters for a command, 4,096 for a URL, 5,000
  for a field value — each matching the ceiling its own caller already enforced,
  so the throw is a fail-closed backstop rather than a new limit. Local Terminal
  gained the 2,000-character guard that Isolated and child Terminal already had,
  returning an ordinary Tool refusal instead of running an unshowable command.
- **Evidence.** Nine tests were written first and failed for the right reasons
  (7 red on the helper, plus the Local guard case), then passed. The two original
  reproductions now invert: the two 519-character form values produce different
  display text *and* different fingerprints, and the 5,002-character command is
  refused with zero characters reaching the executor. Full gate on the merged and
  fixed tree: 2,514 passed, zero failures, five existing browser skips, 16 tasks
  without errors or warnings. `Invoke-ScriptAnalyzer` shows no new warning against
  the pre-merge baseline for either edited file.
- **FIND-009 and FIND-010 remain open.** Both are Minor, neither blocks the
  merge, and both are carried as follow-up work rather than closed silently.
- Specification 050 no longer claims the command is "bounded and marked when
  truncated"; it now states the refusal rule and why a shared prefix would
  otherwise collide.

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
