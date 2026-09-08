---
schema-version: 1
status: accepted
owner: shared
last-verified: 2026-09-08
source: FIND-011 and FIND-012 fixes, focused regressions, and final full Sampler gate
---

# Active context

## Current focus

Close FIND-011 and FIND-012 on `ai/intercom-group-mentions`. Direct plain-text
replies to the current pending question in its recorded group now work without
a mention. Specification 110, the operator guide, and the Unreleased note are
aligned. FIND-013 through FIND-016 remain outside the requested scope.
Normal user Settings and Telegram credentials were not changed; no Merge, push,
or publication is authorized.

The allow-list runs first. The reply exception requires a positive pending
Message id and an exact nonempty chat binding. It covers answers only, not
commands, edits, Attachments, or unrelated free text after **Something else**.
Other group Messages still require exact Telegram mention entities; private
Messages and Keyboard callbacks are unchanged. A direct pending answer works
even when `getMe` has not supplied the username. No Permission is granted.

## Verification

- FIND-011's two new acceptance cases failed before the fix, then passed.
  All 209 Intercom tests now pass, including actual intake-to-answer-bridge
  delivery, same-group acknowledgement, and command/edit/Attachment guards.
- Both changed PowerShell files parse, with zero new analyzer findings and
  three pre-existing findings. Specification, guide, and changelog render.
- Final full Sampler gate completed at 06:28:46 UTC: 2,551 passed, zero failed,
  18 skipped, zero unrun; 17 tasks with zero errors or warnings.
  Log: `TEMP/deskpilot-find11-full-ede9197c39b64fbbba234a260be1bc3d.log`.

Prior feature evidence, before these fixes:

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

The earlier preview at <http://127.0.0.1:58377> was loaded before FIND-011's fix;
it is not evidence for the repaired answer path. It uses separate temporary
data with no Telegram token. Its private launch URL is encrypted locally;
never print it. Restart the Host Server from the rebuilt module to use the fix.
Do not use a Gallery update notice to replace this development build. No live
Telegram test or preview restart was performed for these two findings.

## Retained release boundaries

Earlier child V3 proof is source-bound and does not prove this rebuilt Host
Server. Child execution remains disabled; its live profile was not rerun.
Strict V2 still lacks the verified provider counter, and the parallel topology
in decision 0005 remains unapproved. Terminal-only live acceptance and
clean-install Engine availability remain separate release work.

The prior approval-truncation finding is fixed. Two Minor follow-ups remain in
[the assessment log](assessment-log.md): unobserved child stderr drains and
missing direct `stopTurn` active-child route coverage. This turn did not change
the Engine worktrees, child execution, or approval authority.

## Review follow-up

FIND-011 and FIND-012 are closed; focused verification and the final full gate
pass. Other findings remain in [the assessment log](assessment-log.md).
Scoped self-review found no new Blocker or Major. Independent subagent tooling
is unavailable; a separate human review of the intake exception is recommended.
