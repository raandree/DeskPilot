---
schema-version: 1
status: accepted
owner: shared
last-verified: 2026-09-08
source: user-authorized main push and GitHub Actions run 34214508250
---

# Active context

## Current focus

The user authorized merging the CI repair into `main`, pushing, and monitoring
CI on 2026-09-08. `main` fast-forwarded from `912b158` to `07b57eb` and was
pushed to `origin/main`. The merge tree exactly matches the tested repair.
Both repair commits (`8cd138e` and `07b57eb`) are included; no force-push or
manual workflow dispatch was performed. The earlier theme preview is stopped.

Pester resolves from `latest` per user policy; the verified version is 6.1.0.
Do not restore the earlier 5.7.1 pin. The original failed run
[34209511633](https://github.com/raandree/DeskPilot/actions/runs/34209511633)
is historical evidence; the current pushed run is
[34214508250](https://github.com/raandree/DeskPilot/actions/runs/34214508250).

The repair passes QA/Unit paths through Sampler's supported
`Pester.Configuration.Run.Path` and keeps Integration tests opt-in. Existing
Windows-only child capture/readiness contracts now have platform-aware tests
and explicit unsupported-host refusal checks. IPC tests compile both channel
types together. The blocked-send test uses dedicated threads rather than
depending on thread-pool availability; its 500 ms Stop assertion is unchanged.

Support bundle creation includes the hidden temporary archive when reading its
size on Unix. Destination protections, no-overwrite behavior, redaction, and
byte ceilings are unchanged. No production child authority code was changed.

## Verification

- Clean local Pester 6.1.0 full gates passed: Windows 2,492 passed, 13 skipped;
  Linux 2,448 passed, 57 skipped. Zero failures, 17 tasks without errors or
  warnings on each. Windows also resolved dependencies. Counts and skips
  match the Pester 5 baseline; no further test rewrites were required.
- The prior local gate passed all 29 JavaScript tests on each platform.
  Existing Support bundle regressions failed before the Unix fix and pass
  afterward. IPC and constrained-thread-pool authority tests pass.
- Current hosted run started at 10:15:50 UTC for exact commit
  `07b57eb94097f0fd41769ccfffac5dbf986763cc`, version `0.5.0-preview.21+113`.
  All five jobs succeeded: Package Module, Windows, macOS, Ubuntu, and Deploy
  Module. Deployment finished at 10:20:46 UTC. Every test job used Pester 6.1.0:
  Windows 2,492 passed/13 skipped; macOS and Ubuntu each 2,450 passed/55 skipped.
  No failures or unrun tests; all three test workflows had zero errors/warnings.
- Deployment published Preview `0.5.0-preview0021`. Public GitHub metadata
  confirms a non-draft prerelease with its NuGet asset; the Gallery metadata
  confirms that exact version, published at 10:20:41.89 UTC. Both were checked
  at 10:24 UTC. This is package publication, not a fresh authenticated child
  runtime or clean-install acceptance proof.
- Static checks and prior self-review passed. Existing IPC test variable
  warnings are unchanged. Independent review remains off; `review: on` is
  recommended for the earlier filesystem change and concurrency probe.

Evidence under TEMP:

- `deskpilot-pester6-windows-2d53969304aa45dc8c6e7c5fefc91986.log`
- `deskpilot-pester6-linux-complete-1add7121a3b447f7a123a75b61400717.log`
- `deskpilot-ci-34214508250-monitor.jsonl`
- `deskpilot-ci-34214508250-{Package,Windows,macOS,Ubuntu,Deploy}.log`

## Next action

CI monitoring is complete and the heartbeat is stopped. A documentation-only
completion record follows the tested commit with `[skip ci]` to avoid another
publication cycle; application and build files are unchanged. No further fix
or rerun is needed for this CI repair. No data migration is required.

The published Preview is available on
[GitHub](https://github.com/raandree/DeskPilot/releases/tag/v0.5.0-preview0021)
and [PowerShell Gallery](https://www.powershellgallery.com/packages/DeskPilot/0.5.0-preview0021).
Installation remains a separate user action. The existing terminal themes and
browser evidence are unchanged; see [the theme guide](../docs/themes.md).

## Retained release boundaries

FIND-011/FIND-012 are already closed; other findings remain in
[the assessment log](assessment-log.md). Earlier child V3 proof is source-bound
and does not prove this rebuilt Host Server. Child execution stays disabled;
the live profile was not rerun. Strict V2 still lacks its verified provider
counter, decision 0005 remains unapproved, and Terminal-only live acceptance
and clean-install Engine availability remain separate release work. This turn
did not change Engine worktrees, child execution, or approval authority.
