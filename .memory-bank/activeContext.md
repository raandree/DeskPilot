---
schema-version: 1
status: accepted
owner: software-engineer
last-verified: 2026-09-24
source: red-green regressions, full Sampler gate, and real browser acceptance
---

# Active context

## Current focus

Implement the near-term agent-engineering recommendations, push the topic Branch,
and keep checking the exact pushed commit until CI is green. The user explicitly
authorized push and CI monitoring, not a Merge to main or package publication.
Work is on `ai/agent-reliability`, based on `3d74541`.

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
- Native static analysis has no errors. The optional DSC style rules conflict
  with the repository's established formatting; their warnings were not hidden
  or presented as a clean configured lint result.

## Boundaries and next action

Delivery is the topic Branch, not main or a package release. Completion requires
Package Module and all three OS test jobs to pass for the exact pushed SHA;
deployment remains skipped. GitHub Actions is the durable CI evidence rather
than a copied status detached from its commit. The next integration decision is
independent review and an explicitly authorized Merge.

The installed ShellPilot 0.4.0 lacks the broader approval callback. An isolated
Copilot SDK 1.0.14 probe proved startup, ping/status and cleanup with zero sessions
or generation, not PowerShell/permission/Usage/MCP parity. Default transport is
unchanged. The separate ShellPilot checkout had unrelated dirty work and was
left untouched. See [compatibility](../docs/engine-compatibility.md).

Keep a private copy of version-2 Memory before a downgrade. Do not promote
confidential Project notes globally as a rollback workaround. Source-bound child
proof must be renewed after these changes; child execution remains disabled and
parallel topology unapproved. Independent review was not requested; recommend
`review: on` before Merge because persistence and approval contracts changed.
