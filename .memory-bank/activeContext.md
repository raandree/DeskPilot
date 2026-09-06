---
schema-version: 1
status: accepted
owner: shared
last-verified: 2026-09-06
source: parallel-Agent prerequisite assessment at DeskPilot 275cd6b
---

# Active context

## Current focus

The requested parallel-Agent implementation stopped at its prerequisite gate.
[Decision 0005](decisions/0005-parallel-agents.md) now distinguishes implemented
child Tool storage from the missing complete child Agent boundary and maps the
readiness refusals to D1/D2 dependencies. The two-child topology and limits remain
proposed, not operator-approved or implemented.

This assessment is on `ai/parallel-agents-prerequisite-gate`, based on the clean
DeskPilot `275cd6b` checkout from `ai/child-agent-isolation`. Only the decision and
routed Memory Bank records change. No concurrency, runtime, Settings, API, UI,
or test implementation changes are authorized by the failed prerequisite gate.
Commit locally; do not push or publish.

## Current verification

- Fresh focused Pester run completed 2026-09-06 12:03:03 UTC: **93 passed,
  zero failures/skips/unrun cases**, with PowerShell 7.6.5 and Pester 5.7.1.
  It covers 65 Terminal approval cases and 28 child policy/readiness/refusal
  cases. Source hashes match; no live Model call or child container was run.
- `Get-DpChildReadiness.ready` is always false. Child startup returns disabled,
  unavailable, or busy without a container launch or ordinary Turn fallback.
  An enabled Setting and a prepared Tool image do not establish readiness.
- `Invoke-ShpBatch` in tracked Engine `d1e1e13` supplies batches, not delegation:
  pooled Runspaces, shared invocation policy, empty histories, no streaming or
  progress, and completed-spend checks instead of in-flight reservations.
  With `AsJob`, Usage stays in the job's Engine store, not the caller's store.
- Native Markdown rendering and local links pass. Independent documentation
  review approved the frozen change with zero Blockers/Majors/Minors and one
  evidence-attribution Nit. The unnecessary Engine cleanliness claim was removed;
  that correction is author-verified. The earlier runtime correction was not
  independently re-reviewed. Decision 0005 retains the exact review evidence.

## Blocked next work

Complete the separately approved
[single-child V2 prerequisite](decisions/0009-single-child-isolation.md) first:
verified whole-request token bounds, Engine-priced reservations, failed/unknown
Usage and cancellation; credentialless Engine containment and trusted transport;
child approvals; combined resource limits; restart/retention integration; and
authenticated live proof. Local Engine groundwork is not obtainable released
support. Do not patch ignored dependencies or enable startup to bypass a gate.

D3 additionally needs explicit operator approval of the two-child topology.
The public-evidence child requires an approved public-only input and governed
retrieval profile; V2's network-disabled File/Terminal profile does not supply
it. Keep all child startup unavailable until the complete profile is proven.

## Retained single-child work

The operator approved V2 and limited tracked Engine changes on 2026-09-06, not
parallel scheduling or application to the real Project. Private Tool storage,
baseline capture, authenticated IPC, bounded export, lease, Stop/recovery,
retention admission, and Host Server refusal exist. No child Engine has run.

Retained final proof: 87 component tests, including 19 real-container cases;
DeskPilot full gate 2,373 passed with five existing browser skips; Engine full
gate 1,749 passed, no skips, 88.79% coverage. These full gates were not rerun for
this assessment. Decision 0009 owns their source and artifact provenance.

The earlier runtime review still requests changes: its credential-filter Major
was corrected with red/green tests but not independently re-reviewed; two Major
admission/integration gates and a retention/restart Minor remain open. A new
documentation review cannot close those findings or authorize release.

The Engine linked worktree remains `D:/Git/ShellPilot-child-isolation` on
`ai/child-provider-boundary`. Preserve the unrelated modified public test in
the original ShellPilot worktree on `ai/edit-file-tool`. No new dependency,
host privilege change, or remote mutation was performed for this assessment.

## Retained release follow-ups

Optional isolated Terminal implementation, prior full Sampler/Docker/UI evidence,
and its documentation closeout remain in
[decision 0001](decisions/0001-isolated-tool-execution.md) and the
[operator guide](../docs/isolated-terminal.md). The previous live attempt returned
`auth_required`; live operator acceptance and an obtainable enforcing Engine
remain separate release gates. No authentication or production Settings were
changed for this assessment.

Earlier browser and Intercom detail remains in the
[archived active context](archive/active-context-2026-09-05.md).
