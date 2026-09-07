# DeskPilot Prompt File order

Use this guide to choose the next implementation task. Complete one scoped
change and its verification before starting dependent work. Status was
reassessed on 2026-09-07; current source and accepted amendments take precedence
over older wording in the original Prompt Files.

Implemented prompts can remain here while distribution or profile acceptance is
open. Do not rerun their completed implementation. The
[archive](archive/README.md) records the other completed features.

## Current status

| Prompt | Implemented | Still open |
| --- | --- | --- |
| [Per-call approval](implement-per-call-approval.prompt.md) | Ordinary Terminal approval, including explicit **Allow once** and **Allow for this Turn**. | Outside-Project native File writes and potentially mutating MCP calls require the Engine contract in specification 120. |
| [Isolated Tool execution](implement-isolated-tool-execution.prompt.md) | Optional Local/Isolated Terminal execution, scoped mounts, default-deny network, limits, lifecycle, and review. | Separate authenticated Terminal-only acceptance and a compatible Engine obtainable on a clean installation. |
| [Child Agent isolation](implement-child-agent-isolation.prompt.md) | Approved single-child V3, confined File/Terminal, approvals, quotas, Stop/recovery, private proposals, full tests, authenticated built-runtime proof, and independent review. | Supporting Engine distribution and proof for each exact prepared installation. Enablement remains explicit. |
| [Parallel Agents](implement-parallel-agents.prompt.md) | Proposed design and dependency analysis only. | Updated topology approval, two-child scheduling, aggregate limits, combined proposal review/apply, UI, and complete proof. |
| [Microsoft 365 integration](implement-microsoft-365-integration.prompt.md) | Read-only identity and data-flow contract recorded. | Application registration, tenant/test account and consent, Graph-versus-governed-MCP choice, implementation, and live verification. |

## Proceed next

1. **Integrate the completed Engine work.** Follow the merge guidance below.
   Preserve the newer `edit_file` security changes on `main`; the child work is
   complete without waiting for the separate `ToolCallApprover` feature.
2. **Close Terminal-only acceptance.** Use the approved enforcing Engine and a
   non-sensitive Project to verify authenticated execution, approval, Activity,
   Usage, Stop, cleanup, and Undo. Authentication has been restored; do not
   repeat the old sign-in blocker without a new failing operation. Single-child
   live proof does not substitute for this distinct Terminal-only workflow.
3. **Implement specification 120 in ShellPilot, then finish File/MCP approval.**
   Start a separate scoped Engine task after explicit permission to edit that
   repository. Add the synchronous `ToolCallApprover` contract with immutable
   call identity, annotation validity/provenance, and structured denial. Prove
   approval happens before effects, cancellation refuses dispatch, and neither
   category nor Tool policy can be overridden. Then invoke the
   [approval prompt](implement-per-call-approval.prompt.md) for its remaining
   DeskPilot scope only.
4. **Revise and approve the parallel design before runtime work.** Rebase
   [decision 0005](../../.memory-bank/decisions/0005-parallel-agents.md) on the
   completed V3 boundary. Its old missing-child claims are historical. Explicitly
   decide how estimated budgets apply to planning, children, synthesis, and
   aggregate reservations; V3 approval did not approve two-child financial or
   resource limits. Then implement scheduling, cascading Stop/recovery,
   deterministic combined proposals, conflict handling, conditional apply/Undo,
   and parent/child UI. Public-evidence retrieval needs its own approved boundary;
   never enable general child network access to obtain it.
5. **Start Microsoft 365 when identity prerequisites exist.** Supply the client
   id, tenant, consenting test account, and non-sensitive fixtures; select the
   smaller auditable Graph or governed MCP boundary. Implement one read-only
   workflow under [decision 0002](../../.memory-bank/decisions/0002-microsoft-365-read-only-slice.md).
   No sending, sharing, mutations, scheduled use, or Intercom use in this slice.
   This task is independent and can move earlier when those prerequisites exist.

## Turn-wide approval contract

On 2026-09-07 the operator explicitly requested **Allow for this Turn**.
[Decision 0011](../../.memory-bank/decisions/0011-turn-wide-terminal-approval.md)
supersedes the earlier no-Turn-grant rule for ordinary Terminal commands.

- The window offers **Allow once**, **Allow for this Turn**, and **No**.
- A Turn grant covers the same Terminal Tool, Conversation, Turn, Project,
  working directory, and frozen execution policy. It does not alter Permissions,
  mounts, network grants, credentials, or limits.
- Stop, completion/failure, a new Turn, or live Permission/Project/policy
  revocation invalidates the grant. It is not a persistent safe-list entry.
- Browser and child approvals remain action-scoped. Intercom answers remain
  once-only; a parent grant is never inherited by a child.
- Native File/MCP approval remains separate work. Do not treat a Terminal grant
  as authority for another Tool class.

## ShellPilot merge guidance

ShellPilot child support was merged into `main` as `4ab9eed` and pushed to
`origin/main` on 2026-09-07. Production source auto-merged. The only conflicts
were `.memory-bank/activeContext.md` and `.memory-bank/progress.md`; their
resolution retains both the newer cross-platform `edit_file` security history
and child-provider completion evidence.

The merged Engine passed 1,937 tests with zero failures, three existing
Unix-only skips, zero unrun cases, and 89.04% coverage; all 16 tasks completed
without errors/warnings. DeskPilot passed all 117 approval contracts against
the exact merged module after closing the independent review's test-only Minor.
The fetched and subsequently verified remote tip matched the local merge.

What remains is **distribution**, not source integration: publish an approved
ShellPilot package and rebuild/re-prove DeskPilot against that exact released
Engine before enabling child execution on a clean installation. Do not reuse
the older source-bound child proof after Host Server or Engine changes.

The future File/MCP approver is a new feature, not unfinished V3 implementation.

## Proof and distribution boundaries

Single-child V3 uses **estimated** provider budgets, not guaranteed invoice
caps. Strict V2 remains unavailable without its verified counter; that is not
a reason to restart or weaken the approved V3 implementation. See the
[V3 operator guide](../../docs/single-child-v3.md).

Prepare and prove the exact Host Server, Engine, runtime, images, and policy
before enabling children. Source-mode and built-mode proof fingerprints differ.
No local commit, passing component test, or prepared image alone is a release.

## See also

- [Feature selection](../../specs/100-feature-selection.md).
- [Remaining Engine approval contract](../../specs/120-per-call-approval-engine-contract.md).
- [Child prompt checks](evals/child-agent-isolation.md), which are not runtime proof.
