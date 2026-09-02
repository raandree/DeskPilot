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
| FIND-001 | High | 8.1 | `/undo` and `/delete` never call `Test-DpIntercomProject`, so any group member can rewrite files on disk and destroy Conversations in any Project, opted in or not | open |
| FIND-002 | High | 7.1 | The per-Project `intercom` flag cannot express "me but not the group"; ticking the group box silently extends every already-opted-in Project, including `git push`, with no re-confirmation | open |
| FIND-003 | Medium | 5.3 | The audit log records no sender for an accepted command, so a now-multi-user feature cannot attribute an action to a person. `fromName`/`chatId` are computed by `ConvertFrom-DpIntercomUpdate` and discarded | open |
| FIND-004 | Medium | 4.3 | Work bound to a chat that was just de-authorised is still delivered there: the `chatId` PUT branch clears no queued prompt, and neither branch clears an in-flight `Download` | open |
| FIND-005 | Low | 2.6 | No allow-list re-validation at enqueue time. `ReplyChatId` is stamped from an attacker-controlled `$command.chatId` *before* the rejection check; only an early `return` keeps "never answer a caller you just rejected" true | open |
| FIND-006 | Low | — | `getMe` failure is swallowed with no log, unlike every other Intercom error path | open |
| FIND-007 | Nit | — | `^-\d{1,20}$` admits ids wider than int64; mirrors the pre-existing `chatId` pattern | open |

FIND-004 and FIND-005 share one structural fix: resolve and **re-validate** the
target chat against the live allow-list inside `Send-DpIntercomMessage`, instead
of enumerating every place that has to clear stale routing state.

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
