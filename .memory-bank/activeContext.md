---
schema-version: 1
status: accepted
owner: software-engineer
last-verified: 2026-09-25
source: independent review, exact-SHA hosted CI, and local regression evidence
---

# Active context

## Current focus

The requested fix, independent re-review, push and CI repair are complete for
code/test commit `ee0d2c9` on `ai/agent-reliability`. All four original findings
and three follow-up observations are closed. No main Merge, package publication
or default Engine replacement occurred; those remain user-controlled.

The fix baseline is `11490f7`; the compatibility Engine is pinned to
`08a4a22e07cb5887996bc4262c638b360f5de74e`. Final record-only changes are checked
by the same CI workflow without changing executable files.

## Completed local fixes

- `34d1e40`: DP-2026-001 validates case identifiers before allocating paths and
  passes launch values as JSON data through a fixed `-File` launcher. Capture or
  process-tree cleanup failure retains owned state, blocks further live trials
  and fails the run. All 217 focused eval regressions pass.
- `864afae`: DP-2026-002 Memory extraction scope, current notes and bounded
  Conversation text are JSON data, not interpolated fence contents. Exact text
  is preserved. Five new tests failed before the fix; 95 Memory tests passed.
  This is framing hardening, not a claim to solve general prompt injection.
- `5093f3d`: DP-2026-003 supports the real `ToolCallControl` schema-1 Pre hook and
  retains the legacy `ToolCallApprover` adapter. Bind effective argument bytes,
  derive the already-permitted policy fact from the Engine contract, translate
  decisions and use explicit closed failure posture. Capture original MCP Tool
  identities from registrations; do not reverse lossy namespaced names.
- The same commit closes DP-2026-004 source-marker dependence. Local registration
  and Isolated readiness share a bounded negative/positive inert dispatch proof
  in a separate Runspace. Cache by module bytes and loaded command digest.
  A comment containing the old marker cannot pass the behavioral test.
- CI now builds the immutable compatibility Engine and supplies its manifest to
  every OS test job. Its missing DocGenerator build dependency was reproduced,
  then resolved through the Engine's declared dependencies in the build cache.
- `17f6333`: real-browser acceptance found approval cards were appended to a
  hidden container. Reveal that container on a valid request, with permanent
  renderer regressions and an uninstrumented browser rerun.

## Local validation

- Full combined `build.ps1 -Tasks build,test` at `84a6012`: 2,966 passed, zero
  failures, nine skips, no unrun tests; 16 tasks, zero errors, seven expected
  negative-path Memory preservation warnings. All 59 native Node UI tests pass.
- All 95 Terminal/Turn-grant cases ran with the real pinned Engine, including
  the five tests previously skipped by source-marker selection.
- Six real-Engine integration cases prove File/MCP approve and deny, native
  policy precedence and disabled-Terminal refusal. Provider responses and
  execution are inert fixtures; no network, credentials or paid Model requests.
- Modern mapping and legacy compatibility tests pass, including correlated
  identity validation before read-only admission. Native analyzer is clean on
  the new control/probe helpers; one existing pure Memory-builder warning remains.
- Actual built Host Server and pinned Engine pass browser approval journeys at
  1440px and 390px: no pending write, denial prevents the write, approval writes
  exact fixture content, cards fit, and zero page errors. Provider responses are
  scripted; credential and network paths throw. This is not live Model proof.
- Workflow YAML/embedded PowerShell parsing and directly related Markdown
  rendering passed. Native test results and browser screenshots are retained.

## Review and hosted CI

Independent re-review approved the original four closures at `17f6333`, then
approved `84a6012` and closed all three follow-up observations: exact Tool names,
early MCP catalog compatibility errors, and direct CI artifact/error checks.
No new findings remain. The final full local gate passed after those repairs.
Production analyzer has no Warning/Error findings; three pre-existing Pester
cross-phase warnings remain unchanged. The reviewer independently confirmed
the real Engine and behavioral boundary cases ran, not skipped.

The first hosted run exposed only a macOS fixture alias mismatch (`/var` versus
`/private/var`). Canonicalize the fixture root before child launch; no transport
or non-execution assertion was relaxed. All 173 focused eval tests pass locally.
The previously failing assertion then passed on the hosted macOS runner.

[CI run 36122275951](https://github.com/raandree/DeskPilot/actions/runs/36122275951)
is verified green at `ee0d2c9dfce152ff73e86951fb2291f5acc0ee29`:

| Gate | Result |
| --- | --- |
| Package Module | Passed, including the pinned Engine build |
| Windows | 2,966 passed, zero failures, nine skips |
| Ubuntu | 2,920 passed, zero failures, 55 skips |
| macOS | 2,919 passed, zero failures, 56 skips |
| Deploy | Skipped as intended for the topic Branch |

The native Engine cases ran on every OS. No live Model acceptance is claimed.

## Retained boundaries

Terminal-only approval remains the default. Permissions, isolation and child
opt-in are unchanged; source-bound child proof is invalidated by source changes
and must be renewed before enablement. Parallel topology remains unapproved.
Memory provenance and per-Project scope remain Host-controlled. Keep a private
copy of version-2 Memory before downgrade; never promote confidential notes to
global scope merely to retain them in an older build.

The separate ShellPilot source checkout is untouched. All four task-owned
worktrees and browser dependencies were removed after verification. Review
reports, immutable diffs, test results, CI logs and browser evidence are retained
in session storage. No further implementation is planned for this request.
