---
schema-version: 1
status: accepted
owner: software-engineer
last-verified: 2026-09-06
source: explicit operator approval, decision 0009, current policy, and live evidence
---

# 0010 - Single-child budget amendment

This amendment changes only the provider-budget contract in
[single-child V2](0009-single-child-isolation.md). It is for the operator who
approves the guarantees and the engineers implementing the complete child
profile. It does not claim that child execution is ready.

## Approval and scope

On 2026-09-06 the operator explicitly selected **Approve and implement
single-child V3** after reading the concrete budget trade-off and preserved
boundaries. This approves the amendment and test-first implementation, full
proof, and the required independent security review. It does not claim that
the runtime has been implemented or proven.

The amended profile is named `single-child-v3`, with explicit
`budgetMode = provider-estimate`. It must never reinterpret an existing V2
policy or silently choose a different Model. All unamended V2 requirements
remain mandatory, including complete child integration and release proof.

Acceptance authorizes estimated token/cost budgets, the request/byte limits
below, and the stated counting data flow for this single-child profile. It is
not authority to enable child execution, release a package, mutate a remote,
run concurrent children, or apply proposals to the real Project.

Host Server readiness is a single read-only evaluation owned by the Host
operator. It requires both operator acceptance and a Host-owned profile-proof
record that binds complete gate results and independent review outcomes to
Engine/runtime/adapter hashes, immutable image ids, policy/limit versions,
backend prerequisites, current dependency health, and verified absence of
unresolved cleanup. Any source, runtime, or policy mismatch invalidates prior
proof. Readiness does not replace explicit per-run operator opt-in, and neither
readiness nor opt-in authorizes remote publication.

An operator-invoked proof harness may exercise a candidate only under the same
enforced controller, security, and resource limits. It does not publish
readiness and must not enable ordinary child startup. It is not a gate bypass.

## Evidence and choice

Authenticated probes on 2026-09-06 found a working
`/v1/messages/count_tokens` route for `claude-haiku-4.5` on the Engine-selected
Copilot host. The `/responses/input_tokens` probe for `gpt-5-mini` returned 404.
Messages counter/Engine Chat input pairs were 11/11, 31/31, 587/580, and 669/662.
Omitting explicit `tool_choice` left the counts unchanged. See the
[live counting evidence](../../docs/child-agent-isolation.md#live-counting-investigation).

These observations establish endpoint availability for the tested profile,
not an exact count or universal upper bound. The proposed choice is to use the
hosted count honestly as an estimate, alongside hard local controls. Actual
tokens or charges can exceed the configured estimate budgets; the maximum
possible financial overrun is not established by these controls.

Alternatives considered:

- Keep V2 unchanged: valid when a guaranteed provider spend bound is required,
  but the missing verified counting contract continues to block child startup.
- Declare the hosted count exact, subtract seven, or invent a safety factor:
  rejected. A few observations do not establish an all-input guarantee.
- Use a local character heuristic when hosted counting fails: rejected. It
  changes the agreed measurement source and hides a dependency failure.
- Switch provider, Model, or generation protocol automatically: rejected.
  Such a switch changes authority, data flow, and accounting without consent.

## Limits and unchanged boundaries

Only token and cost budgeting changes meaning. The values below retain V2's
defaults and configuration ceilings; the last column is not a guarantee of
provider consumption or billing.

| Provider budget | Meaning | Default | Maximum configurable value |
| --- | --- | ---: | ---: |
| Input per generation request | Hosted complete-input estimate threshold. | 16,384 tokens | 32,768 tokens |
| Cumulative input plus output | Non-refundable estimated input plus requested maximum output reservations. | 32,768 tokens | 65,536 tokens |
| Output per generation request | Ceiling requested from the provider, checked against reported Usage. | 4,096 tokens | 8,192 tokens |
| Engine-priced cost | Estimated reservations priced by the frozen Engine price table, not an invoice cap. | USD 0.25 | USD 1.00 |

Local enforcement must independently bound the work even when a count is wrong:

| Hard local control | Default | Maximum | Enforcement point |
| --- | ---: | ---: | --- |
| Generation request attempts | 8 | 16 | Trusted transport consumes a slot before dispatch, including failed sends. |
| Counting request attempts | 8 | 16 | At most one count for each generation slot; a failed count permits no generation. |
| Initialization control requests | 2 | 2 | At most one Engine authentication exchange and one Model discovery request. |
| Total outbound HTTP attempts | 18 | 34 | Counts every initialization, count, and generation attempt; no redirects or automatic retries. |
| Serialized request bytes | 256 KiB | 1 MiB | Check both counting and generation UTF-8 bodies before either is sent. |
| Count response bytes | 16 KiB | 64 KiB | Bounded response read before parsing; reuse the event-byte ceiling. |
| Generation response bytes | 1 MiB | 2 MiB | Bounded response read before parsing; reuse the output-byte ceiling. |

The generation attempt count cannot exceed V2's iteration limit. Runtime
preparation/discovery outside a child run is an explicit operator action; a run
does not evade these counters by labeling work setup, refresh, or recovery.
All automatic HTTP retries, authentication retries, API-shape resends, and
redirects remain disabled. A manual new run is a new budget, not a hidden retry.

These controls supplement, never replace, V2's other bounds:

- One child, no recursive delegation, and an idle parent Engine Runspace for
  the complete run. Ordinary Turns, schedules, and helpers cannot overlap it.
- Default duration 300 seconds, maximum 600, including initialization, capture,
  counting, approvals, generation, and export. Every operation is capped by the
  remaining monotonic deadline. Cleanup grace grants no new execution authority.
- Combined memory 1 GiB/2 GiB, CPU 1/2, and process limit 64/64 across both
  containers and trusted transport, with independently enforced partitions.
- Total materialized storage 128 MiB/256 MiB; Tool storage 96 MiB/192 MiB;
  inodes 4,096/8,192. Seeded input, temporary data, request/response buffers,
  export staging, and retained proposals consume their existing quotas.
- Installation retention 512 MiB/1 GiB and 24 hours/7 days. A cleanup or quota
  failure blocks new child work; no unbounded spool or directory-size polling.

All other V2 numeric limits, byte/file limits, leases, and permission checks are
unchanged. Passing a component test is still not proof of whole-run enforcement.

The following security boundaries are not negotiable in this amendment:

- Separate credentialless Engine and Tool containers, no home or host Project
  mounts, no control socket, no inherited credentials, and no shared writable
  storage. Kernel-enforced read-only or separately granted private writes.
- Tool and child Engine network egress remains off. Only the trusted transport
  can contact the approved Copilot provider using Engine-owned credentials.
- Every enabled File and Terminal Tool is confined. Native disabled-Tool
  dispatch is refused; Browsing, browser automation, MCP, arbitrary User Tools,
  Vision path reads, customization discovery, and delegation remain disabled.
- Approvals precede side effects and remain child/request/policy/action-bound.
  No inherited grants, Turn-wide grants, Intercom child approvals, or authority
  expansion through estimates, provider data, child prose, or errors.
- Stop, independent lease expiry, Host Server death, and restart reconciliation
  terminate or refuse work and verify cleanup. No automatic restart or rerun.
- Proposed changes remain bounded, host-validated data. They never apply to
  the real Project or enter its pending changes/Undo as real `filesWritten`.

## Counting, admission, and Usage

The first eligible profile is explicitly selected `claude-haiku-4.5`, using
the Engine's existing Chat generation transport and the hosted Messages count
route. Other Models or request shapes are unavailable until separately tested
and added to the trusted profile; the user's selected Model is never replaced.

The Engine owns conversion to the provider counting shape, authentication,
HTTP, response normalization, and pricing. DeskPilot does not copy provider
implementations or patch ignored dependencies. The trusted transport freezes
the Model, Tool registry, policy, price table, routes, and deadline before launch.
The child cannot choose any of these or supply its own accepted token count.

The operator's run consent must cover disclosure of selected context to both
counting and generation on that approved provider. Counting sees system text,
messages, schemas, and Tool results too; it is not an anonymous local operation.
No extra provider, proxy, or outbound destination is authorized. Resolve the
provider host through Engine-owned authentication and verify the trusted
profile before sending content or credentials; follow no redirect.

Each request follows this order:

1. Validate identities, generation, live Permissions, deadline, request slots,
   message types, frozen Tool schemas, and both serialized request byte limits.
   Unsupported fields or unmappable input refuse counting and generation.
2. Build one immutable normalized request, its deterministic counting body,
   and its generation body. Bind both digests and the exact Model/policy to a
   single request id. Every allowed message, system text, schema, and Tool
   result is represented; no silent omission, truncation, or hidden history.
3. Consume the count slot and call the approved endpoint. A missing, invalid,
   negative, fractional, stale, oversized, timed-out, or refused count stops
   the run before generation. It never triggers a heuristic or Local fallback.
4. Mark the count `estimated`, retain its provider/profile provenance, and
   reserve estimated input plus requested maximum output and Engine-priced
   cost. The count is unmodified; no seven-token correction or hidden margin.
    Unknown pricing or an exhausted estimated budget refuses generation.
    Pricing-unavailable ends the attempt with a distinct
    `pricing-unavailable` outcome.
    The run must not wait for pricing, refresh policy, or retry generation.
5. Recheck cancellation, deadline, live Permissions, frozen policy, and both
   digests; atomically consume the generation slot before exactly one send.
   A refused check sends nothing. A failed send retains its slot and reservation.
6. Validate the provider response and record actual Engine Usage when known.
   Adjust each token/cost charge upward to the larger of its reservation or
   reported consumption; never refund capacity during the run. Estimates,
   reservations, and reported Usage remain distinct values.
7. If actual per-request input, adjusted cumulative tokens, or priced cost
   exceeds its budget, stop before any further Tool or provider dispatch and
   return an explicit budget-overrun result. No request already sent can be
   unbilled or rolled back. A requested-output violation, identity mismatch, or
   malformed Usage remains a contract failure, not a tolerated estimate drift.
8. Missing Usage retains its full reservation, labels totals unknown rather
   than zero, and stops continuation. Preserve known partial Usage and bounded
   failure evidence; cleanup and status reporting continue without new work.

Admission-close and terminal-state rules are strict: budget overrun, unknown
Usage, and pricing/count failure close admission first, then enter stopping,
and become failed only after verified cleanup with their distinct failure
reason preserved. If cleanup certainty is missing, remain in cleanup-failed and
block further child admission. Operator Stop becomes stopped only after
verified cleanup. During stopping or cleanup-failed, cleanup and status actions
are permitted; Tool/provider work is not.

An underestimate that remains within all adjusted budgets is recorded as drift
and may continue. Estimated mode must not reject it merely for being above the
estimate or relabel it a guaranteed count. A count failure never authorizes a
generation. HTTP attempts and deadlines remain hard even when provider Usage
or prices are unknown. Local cancellation cannot guarantee when the provider
stops processing or settles charges for an already dispatched request.

Any manual rerun after explicit operator preparation starts a new run identity
and a new budget. It is never an automatic in-run recovery path.

Keep the existing strict Engine `RequestLimits` / `RequestTokenCounter` contract
backward compatible: `exact` and `upper-bound` retain their meaning, and an
`estimated` count is still rejected without a separate explicit estimated-mode
opt-in. Add that mode through a tracked, tested Engine contract before DeskPilot
uses it. It must not become a global default or be selectable by the child.

## Presentation, migration, and rollback

The effective policy, start consent, approvals, Activity, Usage, and Diagnostics
must carry the profile and budget mode. Show estimated input/cost budgets
separately from enforced local limits. Show reported Usage as reported, retain
unknown/partial status, and make an overrun visible. Never present USD 0.25 as a
guaranteed maximum charge. Count bodies, tokens, secrets, and raw exceptions do
not belong in logs, the transcript, or Support bundles.

Existing installations and V2 policies stay disabled for child execution until
explicitly opted into the new profile after successful preparation and proof.
No automatic policy migration, Model switch, native-Tool fallback, or dependency
installation occurs. Ordinary single-Agent Turns and Terminal-only Local or
Isolated mode are unchanged.

Rollback stops the child, verifies cleanup, disables its profile, and removes
only positively owned child artifacts through the existing removal contract.
Retain bounded evidence and proposals within quota. Do not remove shared
Docker/WSL2 or restore native host execution as a substitute. Selecting V2 again
restores its strict gate, which remains unavailable without a verified bound.

## Acceptance and remaining work

Operator acceptance is recorded above. Implement and verify the amended profile
test-first; design acceptance is not completion of these gates:

1. Demonstrate strict-mode backward compatibility and rejection of estimated
   counts unless estimated mode is explicitly authorized and frozen.
2. Prove complete supported counting conversion, request identity binding,
   no omitted data, unsupported-shape refusal, and secret-safe failures.
3. Exercise equal, over-, and underestimates; exhausted budgets; unknown pricing
   and Usage; invalid results; stale/replayed answers; and non-refundable failed
   requests. Verify no further Tool or provider dispatch on stop conditions.
4. Exhaust request-attempt and byte limits through count, generation, failure,
   authentication, timeout, and attempted resend paths. Verify no redirect or
   hidden retry and cancellation while counting or waiting for the provider.
5. Complete the original V2 credentialless Engine/transport, approval bridge,
   Activity/Usage, storage, complete-run resources, restart/retention, Stop,
   orphan cleanup, hostile-input, and unchanged-Project/index proof gates.
6. Run focused suites, full Sampler gates, a clean actual-runtime profile proof,
   and authenticated end-to-end acceptance. Keep live observations separate from
   deterministic fixtures; a skipped or unavailable gate is not release evidence.
7. Complete independent security review of the finished profile and resolve
   every Blocker/Major, including the earlier credential-filter re-review and
   incomplete integration findings. Update specifications and operator guidance
   with implemented guarantees, not this proposal's intentions.

Approval removes the demand for a guaranteed provider token/cost bound only for
the new profile. It does not complete any missing implementation or validate the
proposed counters, byte controls, or full-run resource enforcement. Clean-install
Engine availability and explicit release authorization remain separate gates.
Parallel Agents, public-evidence retrieval, proposal application, multi-child UI,
and a two-child topology remain outside this amendment.

## See also

- [Single-child V2 decision](0009-single-child-isolation.md).
- [Parallel Agents dependency plan](0005-parallel-agents.md).
- [Child isolation status and live evidence](../../docs/child-agent-isolation.md).
- [Current child policy](../../source/Private/ConvertTo-DpChildExecution.ps1).
