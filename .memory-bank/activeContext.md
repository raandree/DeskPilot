---
schema-version: 1
status: accepted
owner: software-engineer
last-verified: 2026-09-25
source: user-authorized review fixes and executable local validation
---

# Active context

## Current request

Fix all four adjudicated review findings, run independent re-review, then push
`ai/agent-reliability` and repair exact-commit CI until green. The user authorized
that sequence on 2026-09-25 at 08:01 UTC. No main Merge, package publication or
default Engine replacement is requested.

The fix baseline is `11490f7`; the offered Engine is pinned to
`08a4a22e07cb5887996bc4262c638b360f5de74e`. The original reviewed product was
`a7a729e`; its prior green CI is not evidence for these later fixes.

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

## Pending work

Independent re-review approved the original four closures at `17f6333`, then
approved `84a6012` and closed all three follow-up observations: exact Tool names,
early MCP catalog compatibility errors, and direct CI artifact/error checks.
No new findings remain. The final full local gate passed after those repairs.
Production analyzer has no Warning/Error findings; three pre-existing Pester
cross-phase warnings remain unchanged. The reviewer independently confirmed
the real Engine and behavioral boundary cases ran, not skipped.

CI run `36121088703` at pushed `5864cdb` passed Package Module, Windows and
Ubuntu. macOS exposed one fixture-only mismatch: a child reports `/private/var`
while the temporary root used `/var`. Canonicalize that fixture root with the
existing helper; preserve every byte-transport and non-execution assertion.
All 173 focused eval tests pass locally with no skips. Repush the repair and
recheck the complete OS matrix; macOS is not yet reverified. No production
behavior, main Merge, publication or default Engine installation changed.

## Retained boundaries

Terminal-only approval remains the default. Permissions, isolation and child
opt-in are unchanged; source-bound child proof is invalidated by source changes
and must be renewed before enablement. Parallel topology remains unapproved.
Memory provenance and per-Project scope remain Host-controlled. Keep a private
copy of version-2 Memory before downgrade; never promote confidential notes to
global scope merely to retain them in an older build.

The separate ShellPilot source checkout is untouched. The task-owned pinned
Engine build and eval worktree are outside the repository; logs and immutable
review evidence are in session storage. Local approval is complete; CI repair is active.
