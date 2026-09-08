---
schema-version: 1
status: accepted
owner: shared
last-verified: 2026-09-08
source: Intercom regressions, full Sampler gate, and built-preview browser proof
---

# Active context

## Current focus

Complete opt-in mention-only Telegram group intake on
`ai/intercom-group-mentions`. The **Require a bot mention in groups** checkbox
under **Settings > Intercom** persists `intercom.requireGroupMention`, default
`false`. Normal user Settings and Telegram credentials were not changed.
No push or publication is authorized.

The allow-list runs first. With the option on, group and supergroup Messages
need an exact, case-insensitive Telegram `mention` or addressed `bot_command`
entity for the username obtained through `getMe`. Caption entities govern
Attachments. Unmentioned Messages cannot acknowledge edits, answer questions,
queue work, or start downloads. Typed group answers require a mention;
Keyboard callbacks and private Messages are unchanged. An unknown username
admits no group Messages. This is not a Permission or a Telegram privacy change.

## Verification

- Intake and Settings regressions were red before implementation, then green;
  all 195 Intercom cases pass, including real command-handler silence checks.
- All 13 native UI tests pass, including five new checkbox/save/rollback cases.
- Full `build.ps1` gate completed at 05:20:22 UTC: 2,537 passed, zero failures,
  18 skipped, zero unrun; 17 tasks without errors or warnings. The skips cover
  13 child-execution cases and five existing browser Unicode cases.
- Six changed PowerShell files parse with no new analyzer findings; five
  existing findings remain. SPA syntax and edited Markdown rendering pass.
- Real built-preview HTTP/UI checks pass at 1440px and 390px: the checkbox
  persists both values and survives reload, authority settings remain off,
  and no page errors, overflow, or overlapping controls were found. Screenshots
  were reviewed. No live Telegram delivery or Model Turn was exercised.

Full log: `TEMP/deskpilot-group-mention-full-d12fdbfc1bb94af8b80bd7e48a5871b4.log`.
Browser report and screenshots:
`TEMP/deskpilot-intercom-ui-65104d9a6b0a49efb982291f79c147fd`.

## Preview and next action

The built Host Server is running at <http://127.0.0.1:58377> with separate
temporary data and an authorized browser window open. Intercom is off and no
Telegram token is stored there. Its private launch URL is encrypted locally;
never print it. Restart the normal Host Server from the rebuilt module and
enable the checkbox to use it with the operator's existing Telegram group.
Do not use a Gallery update notice to replace this development build.

## Retained release boundaries

Earlier child V3 proof is source-bound and does not prove this rebuilt Host
Server. Child execution remains disabled; its live profile was not rerun.
Strict V2 still lacks the verified provider counter, and the parallel topology
in decision 0005 remains unapproved. Terminal-only live acceptance and
clean-install Engine availability remain separate release work.

The prior approval-truncation finding is fixed. Two Minor follow-ups remain in
[the assessment log](assessment-log.md): unobserved child stderr drains and
missing direct `stopTurn` active-child route coverage. This turn did not change
the Engine worktrees, child execution, or approval authority. Independent review
was not requested; recommend `review: on` for the changed Intercom intake boundary.
