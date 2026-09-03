# DeskPilot Prompt File order

This folder contains implementation Prompt Files for candidate DeskPilot
features. Invoke one Prompt File at a time. Complete its tests, review, and
integration before invoking a Prompt File that depends on it.

Completed Prompt Files move to [`archive/`](archive/README.md), which records
what each one shipped as. This folder holds only work that is still open.

The sequence is a recommendation, not a roadmap commitment. Reassess the
remaining order after each feature because implementation findings can change a
later feature's prerequisites or value.

## Remaining order

1. [Implement per-call approval](implement-per-call-approval.prompt.md) — **partly
   shipped.** Terminal commands are gated (decision 0008); file writes outside the
   Project and mutating MCP calls are not. Those two need the Engine contract in
   [`specs/120`](../../specs/120-per-call-approval-engine-contract.md), so this
   Prompt File stays open with its remaining scope only.
2. [Implement isolated Tool execution](implement-isolated-tool-execution.prompt.md)
   contains Terminal actions. **Its gate is now met** — see below.
3. [Implement Microsoft 365 work integration](implement-microsoft-365-integration.prompt.md)
   begins with one read-only, delegated, least-privilege workflow. Keep send,
   share, and mutation operations out of the first slice.
4. [Implement Playwright browser automation](implement-browser-automation.prompt.md)
   follows approval and isolation. Name one workflow, target environment,
   permitted domains, private-data inputs, and outbound actions before starting.
5. [Implement parallel Agents](implement-parallel-agents.prompt.md) comes after
   approval and isolation because it multiplies concurrency, Permission, Usage,
   cancellation, and file-integration concerns.

## Dependency gates

```mermaid
flowchart LR
    A[Per-call approval: Terminal] --> I[Isolated Tool execution]
    A --> M[Microsoft 365 integration]
    A --> B[Playwright browser automation]
    I --> B
    A --> P[Parallel Agents]
    I --> P
    C[specs/120 Engine contract] --> R[Per-call approval: files + MCP]
```

A Prompt File with an unmet gate may still be invoked for design discovery, but
its own prerequisite section requires implementation to stop before production
code is shipped.

## Gate status changed on 2026-09-03

Shipping Terminal approval moved two gates that the decision records still
describe as closed. Re-derive them before trusting either record:

- **Isolated Tool execution (decision 0001)** records two blockers, and both are
  now stale. It says per-call approval is not implemented — it is, for Terminal.
  It also says the Engine cannot route Terminal execution to a DeskPilot-owned
  backend — it now does: DeskPilot owns `run_command` and delegates to the
  Engine's `Invoke-RunCommandTool` through an injected executor, which is the
  seam an isolation backend would replace.
- **Playwright (0003) and parallel Agents (0005)** each require approval *and*
  isolation. Half of each gate is now met; both remain blocked on isolation.

## Optional timing changes

Move the read-only Microsoft 365 slice earlier when it has higher product value
than isolation. Do not include outbound mutations until the identity and
data-flow contract has been approved.

## Selection source

See the [competitive landscape](../../specs/100-competitive-landscape.md) for
feature rationale, DeskPilot's current baseline, market evidence, and the
selection guidance behind this order.
