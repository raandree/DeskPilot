---
schema-version: 1
status: accepted
owner: shared
last-verified: 2026-09-08
source: user-requested Pester 6 migration and artifact-based CI reproductions
---

# Active context

## Current focus

The user committed and pushed the terminal themes as `912b158` on `main`, then
requested CI monitoring and repair. [CI run 34209511633](https://github.com/raandree/DeskPilot/actions/runs/34209511633)
packaged successfully but failed all three test jobs. Repairs are on local
`ai/ci-test-repair`; no repair push, remote workflow dispatch, or publication
is authorized. The earlier theme preview and watcher have stopped.

The user rejected the Pester 5.7.1 pin and requested Pester 6. RequiredModules
now restores `latest`; the README and repository guidance target Pester 6.
Both clean full gates passed with Pester 6.1.0: Windows 2,492 passed, zero
failed, 13 skipped; Linux 2,448 passed, zero failed, 57 skipped. Each completed
17 tasks without errors or warnings and returned exit zero. Windows also ran
dependency resolution. No test rewrites or assertion changes were needed after
the earlier CI fixes. Counts and skips match the Pester 5 baseline; the earlier
5.7.1 results below are historical evidence only.

The first Pester 6 Linux attempt lacked Node.js in the local container, causing
22 failures and 199 skips. Correcting that validation harness required no
repository code changes. Do not report that attempt as a Pester incompatibility.

Pester 6 logs under TEMP:

- `deskpilot-pester6-windows-2d53969304aa45dc8c6e7c5fefc91986.log`
- `deskpilot-pester6-linux-complete-1add7121a3b447f7a123a75b61400717.log`

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

- Reproductions use clean copies of `912b158` and the downloaded CI artifact:
  Sampler 0.120.1, ShellPilot 0.3.1, PowerShell 7.6.5. Pester 6.1.0 from the
  original artifact is replaced by the verified 5.7.1 pin.
- Focused Linux baseline: 57 passed, 31 failed. After the initial fixes:
  53 passed, zero failed, 38 platform skips. Existing Support bundle tests
  failed before the hidden-file fix and pass afterward.
- Initial repaired Windows full gate: 2,492 passed, zero failed, 13 skipped.
  Full Linux exposed duplicate channel compilation and a queued Stop probe.
  All 12 IPC tests now pass together; all nine authority tests pass with only
  one thread-pool worker, which deterministically starved the original probe.
- Final Linux default build: 2,448 passed, zero failed, 57 platform skips;
  17 tasks without errors/warnings. Final Windows test workflow: 2,492 passed,
  zero failed, 13 skips; nine tasks without errors/warnings. All 29 JavaScript
  tests pass on each platform. Both detached result markers are zero.
- Hosted/macOS verification remains pending a user-authorized push. Static
  parsing passes; the production helper has no analyzer warnings/errors.
  Existing IPC test variable warnings are unrelated to the changed setup.
  Self-review found no Blocker/Major. Independent review is off; recommend
  `review: on` for the Support bundle filesystem change and concurrency probe.

Final logs under TEMP:

- `deskpilot-ci-linux-final-93d5817952e24611b4ce9b5f06c88b51.log`
- `deskpilot-ci-windows-final-3056cf47e11642f290ad0e5ca67f4ce6.log`

## Next action

The local repair is verified and ready for user-controlled integration and a
hosted recheck. Retain the failed remote run as historical evidence. No data
migration is needed; reverting the repair commit restores the previous code
and build configuration. A push to `main` can trigger publication
when repository secrets are configured; do not infer permission to push from
the request to monitor CI. The existing terminal themes and their earlier
browser evidence remain unchanged; see [the theme guide](../docs/themes.md).

## Retained release boundaries

FIND-011/FIND-012 are already closed; other findings remain in
[the assessment log](assessment-log.md). Earlier child V3 proof is source-bound
and does not prove this rebuilt Host Server. Child execution stays disabled;
the live profile was not rerun. Strict V2 still lacks its verified provider
counter, decision 0005 remains unapproved, and Terminal-only live acceptance
and clean-install Engine availability remain separate release work. This turn
did not change Engine worktrees, child execution, or approval authority.
