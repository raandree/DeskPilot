---
schema-version: 1
status: accepted
owner: shared
last-verified: 2026-09-07
source: final Sampler gates, authenticated built-runtime proof, and independent review
---

# Active context

## Current focus

The approved single-child V3 implementation is complete and locally verified.
[Decision 0010](decisions/0010-child-budget-estimates.md) explicitly permits
`provider-estimate` token/cost budgets, not guaranteed invoice caps. Separate
credentialless Engine/Tool containers, hard local limits, exact approvals,
Stop/recovery, and private proposals preserve the accepted isolation boundary.
Ordinary Turns and strict V2 retain their behavior. Parallel Agents, automatic
proposal application, remote publication, and production enablement are outside
this task.

## Final V3 evidence - 2026-09-07

The two local topic branches are `ai/complete-child-isolation` and
`ai/child-provider-boundary` in `D:/Git/ShellPilot-child-isolation`. Local
close-out commits are recorded in Git. The original ShellPilot checkout and its
unrelated edits remain untouched. No push, release, or package publication.

- Engine: 1,915 passed, zero failures/skips/unrun, 89.2% coverage; 16 tasks,
  zero errors/warnings, completed 01:05:31 UTC. Log under TEMP:
  `v3-full-engine-final-b20dc432c10a47f1a34805d1e5d9d1e7.log`.
- DeskPilot: 2,454 passed, zero failures, five existing browser Unicode skips,
  zero unrun; 16 tasks, zero errors/warnings, completed 01:59:14 UTC. Log:
  `v3-full-deskpilot-exclusive-2575dc3a7f694ec6a15a50a9cd7ded54.log`.
- Independent review's one Major and paired Minor were fixed test-first:
  six expected red cases, then 37 baseline cases passed. Scoped independent
  recheck resolved both. Post-fix full/live gates satisfy its approval condition;
  zero Blocker/Major findings remain. Reports, hashes, and closure ledger:
  `TEMP/deskpilot-v3-review-20260907`.
- Final authenticated built-controller proof completed 02:00:15 UTC: two
  initialization, two count, and two generation attempts; 1,601 input and 87
  output tokens, USD 0.002036, 1,857 reserved tokens/USD 0.00328125. Real private
  File read, unchanged Project, no writes/commands/proposals, cleanup verified.
  Log: `deskpilot-v3-built-live-f6e8d33067684f45986136d65d2b758c.log`.
- Built/source equivalence: 311 functions and 39 child/UI assets match.
  Real built SPA passed at 1440px/390px with zero page errors or panel overflow;
  unauthorized Diagnostics returned 401 and disabled child start returned 403.
  Prior hostile-output browser proof remained inert with no outbound requests.

The first post-fix full run transiently failed six existing Git snapshot cases.
All 884 helper cases and the exclusive full gate then passed with a stronger
error assertion. No production snapshot fix was made; overlap with live proof
is a hypothesis, not an established cause. Preserve the failure log and diagnose
the returned snapshot error if it recurs.

## Local preview and remaining release boundary

The actual built Host Server is running at <http://127.0.0.1:56992> in a
separate temporary data directory. Its authorized browser window is open.
Never print its private launch token. Child readiness is true for this exact
prepared build, but `childExecution.enabled` is false. Ordinary user Settings
were not changed. The user must separately enable V3 and consent per run.

Data and built proof: `TEMP/deskpilot-v3-live-0f4a8933488f469eb7baa3e5103c8283`.
Only exact proven image tags are retained; no child containers remain. The
source-bound proof is for the built Host Server, not dot-sourced development.
Rebuilding or changing source/runtime/Engine invalidates it. Do not click the
older Gallery update as a substitute for this explicit development build.

The [operator guide](../docs/single-child-v3.md) covers limits, preparation,
proof, consent, and removal. Clean-install availability of the supporting Engine
and release authorization remain separate work. No parallel topology approval
or scheduling was added. Earlier sections below are historical groundwork,
not current V3 completion or readiness status.

## Counting evidence

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
V3 may use the hosted value only as an explicitly authorized estimate under
decision 0010. Child-startup refusal remains until the full profile is proven.
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
That earlier close-out is historical. Decision 0010 now authorizes V3 estimated
budgets without weakening isolation. Complete child integration and whole-child
authenticated live proof remain to be implemented and verified.

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

The strict [V2 prerequisite](decisions/0009-single-child-isolation.md) still
lacks a verified provider counter and remains unavailable. V3 now supplies the
complete reviewed implementation under its separately approved estimate
contract. The earlier component-review integration and retention findings are
closed by the full profile evidence above. Recursive delegation and parallel
scheduling remain unavailable.

[Decision 0005](decisions/0005-parallel-agents.md) still requires operator
approval of the two-child topology. Its public-evidence profile needs a separate
approved retrieval boundary. V3 review does not approve either expansion.

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
