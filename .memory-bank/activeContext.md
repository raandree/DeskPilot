---
schema-version: 1
status: accepted
owner: software-engineer
last-verified: 2026-09-25
source: independent review, adjudicated reproductions, and pinned Engine proofs
---

# Active context

## Current focus

The user requested `review: on` for `ai/agent-reliability` at `a7a729e` and
offered ShellPilot `ai/agent-modernization`, pinned to `08a4a22`. An independent
security/quality review is complete: **request changes**. Merge approval is
withheld; no product fixes have been applied in this review turn.
No new push, Merge, release or default Engine replacement is authorized.

The pinned Engine rebuilt successfully (seven tasks, no errors or warnings).
Existing no-provider selectors passed 174 tests on Pester 6.2.0 with five
Terminal-dispatch skips. Separate native controls proved deny-before-write,
allow-before-write and disabled-Terminal dispatch refusal. DeskPilot's current
readiness probes nevertheless both return false: the new Engine exposes a
Hashtable `ToolCallControl`, not ScriptBlock `ToolCallApprover`, and its refactor
no longer matches the Terminal source-marker probe. This is a compatibility
observation, not proof of every integration boundary. No Model was called.

## Adjudicated findings

- **DP-2026-001, Major / High, new:** the evaluation case id enters a quoted
  generated PowerShell launcher. Actual validation/allocation accepts a crafted
  id, and inert AST proof places an injected argument subexpression before Host
  startup. Generated code was not executed. Reject unsafe ids and keep paths
  out of executable interpolation. This blocks Merge.
- **DP-2026-002, Minor / Low, pre-existing:** raw Memory prompt fences can be
  duplicated by Message content. Both base/head builders show the same framing.
  No Model compromise or persistent poisoning was proved; escaping is hardening,
  not an authorization boundary. Existing scope/provenance protections remain.
- **DP-2026-003, Major engineering:** newer ShellPilot uses `ToolCallControl`;
  DeskPilot's legacy adapter expects a different request and response contract.
  Fail-closed behavior is correct. Update the integration documentation and add
  a tested translation adapter, not a renamed parameter. MCP identity mapping
  needs verification; annotations alone are not required to prompt every call.
- **DP-2026-004, Major engineering / Low security, pre-existing:** Local inline
  registration and Isolated readiness grep for `offeredBuiltInTool`. The new
  Engine enforces disabled dispatch but fails this marker, also skipping five
  tests. Proven impact is availability, not an unsafe bypass. Replace marker
  dependence with behavior/contract evidence bound to the imported bytes.

## Implemented

- Extend the existing evaluation harness with repeated, isolated trials,
  capability/reliability gates, honest incomplete Usage, bounded artifact reads,
  owned cleanup and offline CI execution. The corpus has 13 honestly labelled
  cases, not 20 claimed real failures; no paid evaluation was run.
- Attribute Agent Memory notes and bind learning to an immutable originating
  assistant Message and its Project. Require `messageId` for learning; reject
  unstamped history. Preserve lossy stores with atomic no-clobber backups and
  refuse over-cap mutations without discarding another scope.
- Show bounded Skill conformance and declared metadata without granting
  Permissions. Prove path containment before reads and refuse child links while
  preserving explicitly configured root junctions.
- Add opt-in `mutating-tools` approval coverage. It requires the Engine's
  pre-dispatch `ToolCallApprover` interface; unsupported Engines refuse before
  effects. Terminal-only remains the default. No child/parallel gate is opened.
- Add bounded, content-free correlated Turn Diagnostics. Activity is observation,
  not approval; missing Usage stays unknown. No telemetry export is enabled.
- Keep compaction's visible transcript intact and report section/reference
  coverage honestly as a heuristic, not proof of summary quality.

## Verification

- Final Windows `build.ps1 -Tasks build,test`: 2,854 passed, zero failures,
  14 skips, no unrun tests; 16 tasks, zero errors. Seven expected warnings come
  from negative-path Memory preservation tests.
- Real Edge/Playwright checks passed at 1440px and 390px: legacy Memory,
  scoped edit/forget, inert HTML-like text, capability refusal, valid/malformed
  Skill metadata and panel bounds. Zero page errors. The Engine was an inert
  fixture and all data was task-owned; this is not live Model acceptance.
- Browser evidence exposed undefined translator and stale editor-response bugs.
  Both retain failing-then-passing Node regression tests; the locale coverage
  test now checks the actual `tr` translator without weakening its assertions.
- The seven baseline Git fixture failures came from `safe.bareRepository=explicit`,
  not line endings. Explicit `--git-dir` setup restored all 41 workbench cases;
  no global Git policy or production Git behavior changed.
- Hosted run `36058468404` passed packaging and Windows but exposed Unix fixture
  assumptions: macOS temporary-path aliases, Windows-only junction creation,
  cleanup after deleting a link target, and a sentinel matching `/private`.
  The exact fixtures were repaired without skipping or weakening their safety
  assertions; all 270 focused local cases pass (one NTFS case-sensitivity skip).
- Native static analysis has no errors. The optional DSC style rules conflict
  with the repository's established formatting; their warnings were not hidden
  or presented as a clean configured lint result.

## Boundaries and next action

Delivery is the topic Branch, not main or a package release. Completion requires
Package Module and all three OS test jobs to pass for the exact pushed SHA;
deployment remains skipped. GitHub Actions is the durable CI evidence rather
than a copied status detached from its commit. Next: select the review fixes,
validate them against the actual Engine contract, and obtain Merge approval.

The installed ShellPilot 0.4.0 lacks the broader approval callback. An isolated
Copilot SDK 1.0.14 probe proved startup, ping/status and cleanup with zero sessions
or generation, not PowerShell/permission/Usage/MCP parity. Default transport is
unchanged. The separate ShellPilot checkout had unrelated dirty work and was
left untouched. See [compatibility](../docs/engine-compatibility.md).

Keep a private copy of version-2 Memory before a downgrade. Do not promote
confidential Project notes globally as a rollback workaround. Source-bound child
proof must be renewed after these changes; child execution remains disabled and
parallel topology unapproved. The review report and inert reproductions are
retained as session deliverables. Fix findings only through an explicit next
work item; the prior green CI is not independent approval of this branch.
