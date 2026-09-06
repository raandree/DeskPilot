---
schema-version: 1
status: accepted
owner: shared
last-verified: 2026-09-06
source: local Git history, Sampler outputs, and bounded authenticated counting probes
---

# Active context

## Current focus

The operator refreshed Engine sign-in. Authentication is no longer the blocker:
`Get-ShpModel -Endpoint Session` returned 43 Models at 21:19 UTC on 2026-09-06.
The earlier DPAPI failure is historical; do not ask for another sign-in without
new evidence of an authentication failure.

Live probes against the Engine-selected `api.enterprise.githubcopilot.com`:
`GET /models` returned 200 with 43 Models; `POST /responses/input_tokens` with
`gpt-5-mini` returned 404; `POST /v1/messages/count_tokens` with
`claude-haiku-4.5` returned 200 and an input count. The Claude counting route
is available on this account and host; support elsewhere was not tested.

Four small fixtures compared hosted Messages counts with Engine Chat Usage:
plain text 11/11, system text 31/31, Tool schema 587/580, Tool result 669/662
(counter/reported input). Removing explicit `tool_choice` did not change the
counts. The four generation requests had an eight-token output cap, no retries,
1,284 reported input tokens, 19 output tokens, and zero executed Tools.

An available server count is not yet the verified complete-request upper bound
V2 requires. Two fixtures matched and two overcounted; the absence of an
undercount in these cases does not prove a bound for every allowed request.
Do not subtract seven, label the endpoint exact, or treat it as a verified bound.
V2, production Settings, Engine source, and child-startup refusal are unchanged.
Source hashes, the temporary reusable probe, and sanitized results are retained
under `$env:TEMP/deskpilot-copilot-count-20260906-2121`.

## Completed admission groundwork

Close out verified admission groundwork for the single-child V2 prerequisite from `main`
(`64b8b16`). DeskPilot work is on `ai/complete-child-isolation`; limited Engine
work remains in `D:/Git/ShellPilot-child-isolation` on
`ai/child-provider-boundary`. No remote mutation or publication is authorized.
The reviewed Engine groundwork is retained in local commit `7b8937d`; it is not
a published or clean-install dependency.

The operator initially requested admission, complete child integration, and
proof/review. After inspection confirmed the missing provider counting contract,
the operator chose **Keep V2 unchanged; close out verified groundwork**.
Estimated-count fallback and weaker hard limits are not approved. Complete
child integration and authenticated live proof remain blocked, not completed.

The Engine now has conditional `RequestLimits` / `RequestTokenCounter`
admission with frozen limits/pricing, pre-dispatch reservations, request-bound
counts, and failed/unknown Usage accounting. Its 38 public admission regressions
pass with an explicitly identified fixture counter. The helper QA repair passed
680 checks, including seven named helper tests. Final Sampler gates passed:
Engine 1,810 tests without failures/skips and 89.12% coverage; DeskPilot 2,373
passed with five existing browser skips. Each ran 16 tasks with zero errors or
warnings. Independent review approved the admission diff with no Blockers/Majors;
its Minor missing-test finding was closed with two parameter-guard cases.
No release or profile readiness claim.
DeskPilot runtime and startup refusal are unchanged.

Current evidence is under `$env:TEMP`:

- `deskpilot-admission-review-20260906-2030` contains both diffs, source hashes,
  full-suite reports, review approval, and the test-only resolution ledger.
- `shp-admission-final-full-4a824e8b899c4609989844727a653408.log` is the Engine
  full gate, completed 20:32:45 UTC.
- `deskpilot-admission-full-042764484c9b4fdb813bcbd080b8e4eb.log` is the DeskPilot
  full gate, completed 20:28:44 UTC. Docker inspection found no child or Terminal
  containers afterwards.
- `shp-admission-review-guards-f770241ad3a7463fa7df486846801f24.log` is the final
  38-case public admission suite, completed 20:45:08 UTC.

## Previous integration verification

- `build.ps1 -Tasks test`: **2,373 passed, zero failures, five existing browser
  Unicode skips, zero unrun cases**. PowerShell 7.6.5, Pester 6.1.0; nine tasks,
  zero errors/warnings, completed 2026-09-06 13:29:28 UTC. Includes the actual
  child-storage and Terminal-container integration suites.
- `node --test tests/Unit/terminal-isolation-ui.test.mjs`: **3 passed**.
- `node tests/live/terminal-isolation-ui.mjs`: passed at **1440px and 390px**;
  screenshots reviewed, no horizontal overflow or overlapping controls.
- Tests preceded `build.ps1 -Tasks build`: **seven tasks, zero errors/warnings**,
  completed 13:31:13 UTC. Built version `0.0.1` imports successfully and exports
  `Start-DeskPilot`. All **34 bundled assets** match their source hashes.
- Built defaults remain Local and child execution disabled; readiness is false.
  Independent Docker inspection found no child or Terminal containers left.
- Integrated diff whitespace check passed. Runtime and tests are unchanged from
  `31f2d07`; the consolidation record changes only Memory Bank files.

Logs and copied test reports are retained under `$env:TEMP`:

- `deskpilot-integrated-tests-be2392aed20d466db73c980d2cd73d2b.log`.
- `deskpilot-integrated-tests-be2392aed20d466db73c980d2cd73d2b.-evidence`.
- `deskpilot-integrated-build-db74317bde79463d9de4ce78c8976362.log`.
- `deskpilot-terminal-ui-DIhsrm` contains the desktop/mobile screenshots.

## Release boundaries remain unchanged

The [single-child V2 prerequisite](decisions/0009-single-child-isolation.md)
remains partial. Private Tool storage, baseline capture, authenticated IPC,
bounded export, lease, Stop/recovery, retention admission, and refusal exist.
Complete Engine request admission, credentialless child Engine/transport,
child approvals/accounting, and restart/retention integration remain open.
The prior credential-filter correction still needs independent re-review;
the two Major integration/admission gates and retention/restart Minor remain.
No child Engine, recursive delegation, or parallel scheduling is enabled.

[Decision 0005](decisions/0005-parallel-agents.md) still requires operator
approval of the two-child topology. Its public-evidence profile needs a separate
approved retrieval boundary. Recommend `review: on` before enabling or releasing
child execution; this consolidation is not an independent security review.

Optional Terminal isolation retains the limitations in
[decision 0001](decisions/0001-isolated-tool-execution.md) and the
[operator guide](../docs/isolated-terminal.md). Live authenticated acceptance
and an obtainable dispatch-enforcing Engine remain separate release gates.
The counting continuation used four capped Model requests after operator
reauthentication. It did not change production Settings or establish the full
operator acceptance profile.

The separate Engine worktree `D:/Git/ShellPilot-child-isolation` remains on
`ai/child-provider-boundary`. The original ShellPilot worktree and its unrelated
modified test on `ai/edit-file-tool` were outside this task and remain untouched.
