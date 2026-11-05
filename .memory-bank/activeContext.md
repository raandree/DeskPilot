---
schema-version: 1
status: accepted
owner: software-engineer
last-verified: 2026-11-05
source: red/green Pester and Node regressions, real-Engine scripted-provider journeys, independent security review, full Sampler gates in an isolated worktree
---

# Active context

## Current focus

Making files sent together from Telegram (an Album) reach Intercom whole, on
`ai/intercom-albums` from `main` `2e6b4c0`, which the user reported on
2026-11-05 with screenshots. The Preview publish below still waits for a push.

### Telegram Albums reach Intercom whole (2026-11-05)

- **Symptom:** six PDFs sent together with the caption "here are 6 files, store
  them" became one fetch, five "One file at a time, please." replies, and a
  Turn on the first PDF with the default prompt.
- **Cause:** Telegram sends an Album as one Message per file, sharing a
  `media_group_id`, with the caption on one of them (the last, for documents).
  Intercom refused every file while another was being fetched.
- **Fix:** one batch per chat (`New-DpIntercomDownloadState`), fetched one file
  at a time, and one prompt once an Album has been quiet for 3 seconds; a lone
  file still runs at once. Images reach Vision as one set. A batch takes at
  most 20 files, and another chat is asked once to wait. In a group that
  requires a mention, the caption's mention addresses the whole Album, and
  unmentioned files are held unfetched for 30 seconds. A finished batch never
  replaces a queued instruction. Switching Intercom off drops the batch and
  `QueuedImage`.
- **Evidence:** `tests/Unit/IntercomAlbum.Tests.ps1`, 18 cases, 15 red first;
  the other 3 guard the lone-file path and the trust boundary. Intercom suites
  285/285, analyzer clean, and the full Sampler gate: 3,141 passed, 0 failed,
  15 skips. No live Telegram run.

### Preview publish from `ai/subagents`

Publishing the next Preview from `ai/subagents` (from `main` `9d3890c`), which
the user requested on 2026-11-05 with `review: on`. The branch carries the
Subagents work, the closed assessment findings, another chat's Intercom
default change (`a1ccaa6`), and the fixes from the pre-publish security review
below. The user pushed `29eaac7` to `main`, but its CI run (`42042027242`) failed
the three scripted real-Engine tests on every OS, so nothing was published.
ShellPilot's CI gate refused the Copilot backend because runners set `$env:CI`
(see debugging-insights). The test-only fix is committed on `main`, and the
next push publishes the Preview.

### Pre-publish security review (2026-11-05)

Recorded in [assessment-log.md](assessment-log.md). The original verdict was
REQUEST CHANGES; after the fixes, the follow-up verdict is PASS.

- **FIND-017 (Critical, already on `main`): DeskPilot User Tools bound PowerShell
  common parameters.** The Engine splats a Tool call's arguments in its own scope,
  so `OutVariable` and `ErrorVariable` could overwrite its gates and run a
  disabled Terminal without approval. Closed on DeskPilot's side by
  `Protect-DpUserTool` after every registration (`b0fb045`). The real-Engine
  regression is in `tests/Unit/UserToolGuard.Tests.ps1`.
- **FIND-018 and FIND-019 (Subagents).** The run records pin their
  `InformationAction`. The ledger charges the Engine's measured spend, so a run
  cut off at its iteration cap or deadline still counts (`dbdc7ed`).
- **My own five-axis review** fixed a fail-open when `Get-ShpTool` fails, and
  added guards that a Subagent inherits every Turn restriction (`30d270a`).

### Subagents (`3ee65d2`)

As in the VS Code chat screenshot the user shared. Decision:
[0012](decisions/0012-bounded-subagents.md); guide:
[docs/subagents.md](../docs/subagents.md).

- `run_subagent` is a DeskPilot User Tool. The Engine's `Invoke-ShpSubagent`
  (spec 045) runs the Subagent synchronously as a strict subset of the Turn.
  The Turn waits, so there is no concurrency and decision 0005 is untouched.
- `permissions.subagents` defaults **off** and needs User Tools plus an Engine
  that passes `Test-DpSubagentSupport` (`subagentsSupported` on `/api/health`).
- Host-owned context travels as `$global:DeskPilotSubagentContext`: catalog,
  parent capability (Disable* switches plus the Turn's own `ToolCallControl`),
  Turn identity, limits and ledger. A legacy `ToolCallApprover` turns Subagents
  off. Subagent Terminal commands are approved once only and neither use nor
  create a Turn-wide grant.
- DeskPilot's Invoker (`ConvertTo-DpSubagentTurnParameter`) mirrors the
  Engine's dispatcher and adds Model, ReasoningEffort, DisableTodoList and
  ExcludeTool. A parity test against the installed Engine guards it. CI's pinned
  compatibility Engine `08a4a22` has the same Subagent sources as ShellPilot
  `main`; only its price table differs, which no Subagent test asserts.
- `DeskPilotSubagent` records become `agent` Activity; the UI shows one card
  per run with Input, Tool calls and Output.

### Open assessment findings

Closed test-first and recorded in
[assessment-log.md](assessment-log.md) as author-verified:

- FIND-010 (`439d3cf`): behavioural `stopTurn` route tests.
- FIND-013: `tests/Unit/SpaNodeTests.Tests.ps1` runs every
  `tests/Unit/*.test.mjs` under `node --test` inside the Pester gate. A
  deliberately failing Node test turned it red.
- FIND-014: the support bundle's Intercom section carries `requireGroupMention`.
- FIND-015: a failed `getMe` names the consequence that applies now and is asked
  again after 30 seconds, then 2, 10 and 30 minutes
  (`Add-DpIntercomIdentityFailure`). Storing a new token forgets the old bot
  name.
- FIND-016: un-addressed group chatter folds into one `unaddressed` audit line
  per chat (`Add-DpIntercomLog -Coalesce`, `messageCount`, `sinceUtc`); the SPA
  shows `×N since <time>`.

### Intercom mention gate on by default (2026-11-05)

- `intercom.requireGroupMention` now defaults to `true`: a Telegram group
  reaches Intercom only through an @mention of the bot, a command addressed to
  it, or a plain-text reply to the pending question in its chat.
- The user chose **new installs only**. A `false` saved by Previews 0021-0026
  is kept on purpose; there is no migration and no settings `version` bump.
  Settings that never stored the key, including 0.4.0 files, get the default.
- The read-site fallbacks in `Update-DpIntercomState`, `Get-DpIntercomPayload`,
  `New-DpSupportBundleRecord` and `Add-DpIntercomIdentityFailure` agree with
  the default; `ConvertFrom-DpIntercomUpdate -RequireGroupMention` keeps its
  neutral `$false` because its only caller always passes the Setting.
- Spec 110, the getting-started guide (new group step 6) and the changelog
  describe it. Validation: 1,494/1,494 across the 13 related suites; Intercom
  Node UI 7/7. The full Sampler gate was not run because another chat's
  in-progress Subagent edits share this worktree.

## Validation

- Full Sampler gate at `dbdc7ed`, run in a separate worktree so the two chats'
  builds could not collide: 3,123 passed, 0 failed, 15 skips; 16 tasks, 0 errors,
  the 7 known Memory preservation warnings. It includes the Intercom default
  change, whose own chat could not run the full gate.
- The installed Engine (0.4.0-preview0016) is function-for-function identical to
  CI's compatibility Engine `08a4a22`, all 153 functions checked. So the
  real-Engine tests run the same Engine code in CI as locally.
- Intercom suites 355/355, Diagnostics 49/49, Node UI 103/103. Subagent and
  stopTurn suites pass under `Set-StrictMode -Version Latest`; the Intercom
  suites set it themselves.
- The Subagent proof includes an end-to-end run through the installed Engine
  (0.4.0-preview0016) with a scripted provider. Headless Edge renders checked
  the Subagent cards in dark, light and a 390 px column. Not a live Model run.

## Retained boundaries

Parallel/background agents stay blocked by decision 0005. The isolated child
run (0009/0010) is a different feature and is unchanged. Terminal-only approval
remains the default; Permissions other than the new one are unchanged. Never
price Models in DeskPilot.

## Open follow-ups

- **The Engine-side root cause of FIND-017 stays open in ShellPilot.**
  `Invoke-Shp` should pass only the exact declared, non-common parameter names to
  a User Tool. DeskPilot's guard covers its own Tools only.
- **Guard the isolated child runtime before child runs are enabled.** Its
  registrations (`source/child/Start-DpChildEngine.ps1`) have no guard; the runtime
  ships off.
- **FIND-009 stays open on purpose.** The fix belongs in the disabled isolated
  child runtime, whose live Docker and Model proof is bound to its source
  hashes. The assessment log records the remediation plan.
- **A live, authenticated Model run of a Subagent has not been done.** It
  belongs to the operator acceptance profile.
- **The `security-reviewer` custom agent cannot start.** It is configured for
  the Model "Claude Opus 5 (copilot)", which is no longer offered. The built-in
  reviewer stood in for it.
- **Check a real Telegram Album end to end.** The Album fix is proven against a
  mocked Telegram only. Also still open: a Project without phone control
  answers every file of an Album with its own refusal (pre-existing); one
  refusal per Album would do.
