---
mode: agent
description: Fix the seven findings from the 2026-09-02 security review of Intercom group chat (commit ee0bdd7).
---

# Fix the Intercom group-chat security findings

Close the findings recorded in `.memory-bank/assessment-log.md` under
**2026-09-02 — Intercom group chat (`ee0bdd7`, branch `ai/intercom-group-chat`)**.
Read that entry first; it carries the evidence, CVSS scores and rationale, and
this prompt does not repeat them.

Context you need: `specs/110-intercom.md` (the authority model, the command
table, accepted risk A3) and the Intercom section of `.memory-bank/systemPatterns.md`.

**Do not enable `allowGroupChat` on the user's machine, and do not push.**

## Order of work

FIND-002 is a design decision. Put the two options to the user before writing
any code for it, then do the rest.

### FIND-002 — the Project flag cannot say "me, but not the group" (High)

`Test-DpIntercomProject -Settings $state.Settings` has no notion of which chat
asked, so ticking the group box retroactively extends every already-opted-in
Project to the whole group, including `git push`, with no re-confirmation.

Ask the user to choose:

- **A per-Project `intercomGroup` flag** (default `false`), checked when the
  command came from the group. Strongest, and it is what would break the lethal
  trifecta recorded in A3. Costs a Settings key, a Projects-tab control, a
  migration path for existing Projects, and threading the origin chat into
  `Test-DpIntercomProject`.
- **Confirmation at the point of enabling**: when `allowGroupChat` is switched
  on, list the Projects it will now cover and require an explicit confirm. Much
  cheaper, but it is a warning rather than a control — say so plainly when
  offering it.

Whichever they pick, update spec 110's authority row and A3 to match.

### FIND-001 — `/undo` and `/delete` bypass the Project gate (High)

In `source/Private/Invoke-DpIntercomCommand.ps1`, `Test-DpIntercomProject` is
called only by `steer`, `new`-with-work and `prompt`. `archive`, `delete` and
`undo` never call it, and `Restore-DpIntercomCheckpoint` has no gate of its own.
So any group member can rewrite files on disk with `/undo confirm` and destroy a
Conversation with `/delete <n> confirm`, in any Project.

Gate `undo` and `delete`. Prefer restricting them to the **primary chat** rather
than to an opted-in Project — they act on the operator's own history and
Checkpoints, not on the group's work. `archive` is reversible; decide whether it
needs the same treatment and say why either way.

Spec 110's command table marks both as *"Needs an opted-in Project: No"*. Update
it, and update the reasoning above it, which currently justifies the split purely
in terms of "runs work in a Project".

### FIND-004 + FIND-005 — one structural fix (Medium + Low)

Do these together; they are the same root cause. Today:

- The `chatId` branch of `putIntercom` in `source/Private/Invoke-DpRouteHandler.ps1`
  clears `PendingQuestion` but not `QueuedPrompt` / `QueuedChatId` / `QueuedImage`.
- Neither that branch nor the `groupChatId` branch clears an in-flight
  `Intercom.Download`, which carries its own `chatId`.
- `Send-DpIntercomMessage` trusts `ReplyChatId` unconditionally, and the pump
  stamps it from `$command.chatId` *before* `Invoke-DpIntercomCommand` inspects
  `kind` — so for a rejected message it briefly holds an attacker-controlled id.

Resolve the target inside `Send-DpIntercomMessage` and **re-validate it against
the live allow-list** (`chatId`, plus `groupChatId` when `allowGroupChat` is on),
falling back to the primary chat and recording a dropped message when it does not
match. That makes "never answer a caller you just rejected" a property of the
addressing layer instead of one early `return`, and it makes stale routing state
harmless rather than requiring every clearing path to be enumerated correctly.

Keep the existing clearing logic as defence in depth; do not remove it.

### FIND-003 — the audit log cannot attribute an action (Medium)

`Add-DpIntercomLog` has no chat or sender parameter, and
`Invoke-DpIntercomCommand` logs an accepted command with `-Detail $Command.text`
only. `ConvertFrom-DpIntercomUpdate` already computes `fromName` and `chatId` for
every message and they are discarded.

Add optional `-ChatId` and `-From` parameters, populate them on every inbound log
call, surface them in `Get-DpIntercomPayload` and in the Status panel row. After a
bad `/undo` the log must answer *who*, not just *what*.

### FIND-006 / FIND-007 — Low

- The `getMe` start in `Update-DpIntercomState` swallows its error with a bare
  `catch`. Route it through `Hide-DpIntercomSecret` and `Add-DpIntercomLog` like
  every other Intercom error path.
- `groupChatId`'s `^-\d{1,20}$` admits ids wider than int64. Tighten it if you
  also tighten `chatId`; leave both alone otherwise, and note the decision.

## Definition of done

- A Pester test per finding that fails against `ee0bdd7`. For FIND-001 and
  FIND-005 especially, assert the refusal — a test that passes for the wrong
  reason is worse than none. Pair each with a positive case proving the branch is
  reached, the way the stall-watchdog pair does.
- Full Sampler gate green: `./build.ps1 -Tasks build, test` in a clean `pwsh`,
  run detached. Baseline to beat is **1370 tests, 0 failures**.
- `node --check` on `source/web/assets/app.js` if it changed; PSScriptAnalyzer no
  new findings.
- `specs/110-intercom.md`, `docs/intercom-getting-started.md` and `CHANGELOG.md`
  updated for anything user-visible. Changelog groups stay in Keep a Changelog
  order.
- Append the outcome to `.memory-bank/assessment-log.md` against each finding id
  rather than starting a new assessment entry, and refresh `activeContext.md`.
- Commit on `ai/intercom-group-chat`. Do not push.
