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

## Validation so far

- Full parent `build.ps1 -Tasks build,test`: 2,901 passed, zero failures,
  nine existing skips, no unrun tests; 16 tasks, zero errors, seven expected
  negative-path Memory preservation warnings.
- All 95 Terminal/Turn-grant cases ran with the real pinned Engine, including
  the five tests previously skipped by source-marker selection.
- Six real-Engine integration cases prove File/MCP approve and deny, native
  policy precedence and disabled-Terminal refusal. Provider responses and
  execution are inert fixtures; no network, credentials or paid Model requests.
- Modern mapping and legacy compatibility tests pass, including correlated
  identity validation before read-only admission. Native analyzer is clean on
  the new control/probe helpers; one existing pure Memory-builder warning remains.
- Existing Node UI tests, workflow YAML/embedded PowerShell parsing and directly
  related Markdown rendering passed. No browser verification is claimed yet.

## Pending work

DP-2026-001 is implemented in an isolated eval worktree at `6b5ac19`, with
191 passing tests: strict case ids and a fixed native-argument/JSON-data
launcher. Parent self-review requested a narrow follow-up for newly added
capture/cleanup error propagation, process-tree failure reporting, PS 7.0
executable-path compatibility and bounded diagnostic log reads. Await the same
implementer, then review and integrate its final commit.

After integration: full final validation, independent re-review of all finding
closures and the fix diff, remediation of any Blocker/Major, durable records,
then push and exact-SHA CI. Do not push before the requested review or report
completion while a required CI job is pending/failing.

## Retained boundaries

Terminal-only approval remains the default. Permissions, isolation and child
opt-in are unchanged; source-bound child proof is invalidated by source changes
and must be renewed before enablement. Parallel topology remains unapproved.
Memory provenance and per-Project scope remain Host-controlled. Keep a private
copy of version-2 Memory before downgrade; never promote confidential notes to
global scope merely to retain them in an older build.

The separate ShellPilot source checkout is untouched. The task-owned pinned
Engine build and eval worktree are outside the repository; logs and immutable
review evidence are in session storage. No remote mutation has occurred yet in
this fix turn.
