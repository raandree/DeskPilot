---
schema-version: 1
status: accepted
owner: shared
last-verified: 2026-09-08
source: runtime preparation probes, red-green regressions, and full Windows Sampler gate
---

# Active context

## Current focus

The user reported a generic Terminal runtime preparation failure. The pinned
Docker build and complete preparation job both succeeded when reproduced from
current source. No active Host Server was available to inspect; its old job
error had already been discarded. Do not attribute that original failure to
Docker availability, disk space, a download, or a checksum without new evidence.

The confirmed diagnostic defect is fixed on the local Branch
`ai/terminal-runtime-diagnostics`: the completion handler retains the exception
through `Protect-DpDiagnosticText`, bounded to 400 characters, alongside recovery
guidance. The UI already uses `textContent`. Tests cover failed-job detail,
credential redaction and length, and successful retry replacing stale failure.

The normal `$LOCALAPPDATA/DeskPilot` data directory had no runtime record.
Preparation there completed at 15:47:24 UTC. The rebuilt module independently
verified it at 15:56:52 UTC: healthy, PowerShell 7.6.5, Docker 29.7.2, no issues,
and zero remaining Terminal containers. The prepared image is:

`sha256:4a73b0f90a203f5bb3cc90c787e15c61950b49a469a0dd12e11f1eac558ce06b`

Terminal Permissions, execution mode, Engine authentication, and child execution
were not changed. The temporary reproduction tag and data directory were removed;
the usable runtime and shared Docker build cache remain.

## Verification

- The failed-job regression first failed on the generic message, then passed
  after the fix. All three new preparation cases passed on Pester 6.1.0.
- `build.ps1 -Tasks build,test`: 2,500 passed, zero failures, eight skips, no
  unrun tests; 16 tasks, zero build errors or warnings. Completed 15:54:07 UTC.
- A final explicit `$using:` test-capture cleanup passed the complete Terminal
  isolation file: 41 passed, no failures or skips. No production change followed
  the full gate.
- ScriptAnalyzer: no test diagnostics or new handler diagnostics. The existing
  handler `ShouldProcess` warning is identical in the baseline. Historical
  changelog heading/list lint warnings remain; the new guide section renders.
- The local Sampler artifact uses its 0.0.1 fallback version. Its bundled assets
  match the prepared runtime. This is local build evidence, not a new release.
- Self-review checked scope, redaction, text-only rendering, job cleanup, and
  unchanged authority. Independent review remains off; `review: on` is
  recommended for the diagnostic error-detail boundary.

Evidence under TEMP:

- `deskpilot-runtime-red-1772306d96f44d20b3b96a982d85cb6b.log`
- `deskpilot-runtime-ready-b1fb8f3aac8b4f929b735a1a94bc7995.log`
- `deskpilot-runtime-sampler-88e6653657db4f47ad8effd8890fa348.log`
- `deskpilot-runtime-terminal-suite-5c34beeca8674caa8b052dd208cd76d2.log`

## Next action

Reopen DeskPilot and run Diagnostics > Terminal runtime > Check. The improved
error detail is in the local rebuilt code, not a newly published package.
There is no data migration. Merge, push, and publication require a new explicit
user request. See [runtime troubleshooting](../docs/isolated-terminal.md#if-preparation-fails).

## Retained release boundaries

The earlier CI repair and Preview `0.5.0-preview0021` publication remain recorded
in [progress](progress.md); no remote changed in this turn. Pester resolves from
`latest`, currently verified as 6.1.0. Do not restore the former 5.7.1 pin.

FIND-011/FIND-012 remain closed. Child execution stays disabled; no live Model
profile was rerun. Strict V2 still lacks its verified provider counter, decision
0005 remains unapproved, and clean-install Engine availability and complete
Terminal-only acceptance remain separate work. Runtime readiness alone does not
prove that the installed Engine meets its dispatch-enforcement contract.
