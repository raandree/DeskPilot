---
schema-version: 1
status: accepted
owner: shared
last-verified: 2026-09-08
source: user-confirmed missing Docker Desktop and red-green prerequisite regressions
---

# Active context

## Current focus

The user confirmed that the separate machine used for testing has no Docker
Desktop installation. That missing prerequisite prevents Terminal runtime
preparation. The earlier successful runtime checks applied only to this
development machine; they did not verify the user's test machine.

The focused fix is on `ai/terminal-docker-prerequisite`. The existing trusted
Docker executable check now raises `DockerDesktopNotInstalled` with explicit
Windows, WSL 2, Linux containers, and Prepare runtime instructions. DeskPilot
does not install Docker Desktop automatically.

The preparation handler recognizes the error identifier after job serialization,
reports `unavailable`, and displays only its redacted installation guidance.
Unknown failures remain `degraded` with the earlier bounded, redacted error and
generic recovery advice. The UI's existing text-only rendering is unchanged.

No Docker installation, runtime preparation, Settings change, or action on the
test machine was performed in this turn. Docker launch settings, trusted paths,
timeouts, Permissions, and execution boundaries are unchanged.

## Verification

- Both new regressions first failed: missing structured prerequisite identity
  and `degraded` instead of `unavailable`. All five preparation tests then
  passed on Pester 6.1.0, including generic failure, redaction, and retry guards.
- Missing installation is simulated through the real executable check; no
  system dependency is removed. A failed job proves error-identifier transport,
  redaction, job cleanup, and omission of irrelevant disk/download advice.
- Full Windows `build.ps1 -Tasks build,test` completed at 17:44:31 UTC:
  2,502 passed, zero failures, eight skips, and no unrun tests. All 16 tasks
  completed with zero build errors or warnings. No production change followed.
- ScriptAnalyzer reports zero diagnostics in the Docker helper and tests, and
  no new diagnostics in the handler. Its existing `ShouldProcess` warning and
  historical changelog heading/list warnings are unchanged. Markdown renders.
- Self-review covered correctness, scope, naming, redaction, job handling, and
  unchanged authority. Independent review remains off. No Model or live test
  machine acceptance was performed.

Evidence under TEMP:

- `deskpilot-docker-prerequisite-red-da34c43ac8b843659f0149d54f9efc48.log`
- `deskpilot-docker-prerequisite-green-e818141cd1c343bb82739b3490016045.log`
- `deskpilot-docker-prerequisite-full-639a2e0bfa36478bbfdfd5222ce9e58a.log`

## Next action

The code and documentation are ready for local commit. On the user's test
machine, install Docker Desktop for Windows, enable its WSL 2 backend and Linux
containers, and start it before selecting Prepare runtime. The rebuilt code
improves the message; it does not satisfy that machine's missing prerequisite.

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
