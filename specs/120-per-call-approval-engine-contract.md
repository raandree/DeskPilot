# Per-call approval Engine contract

This design record documents why DeskPilot cannot yet implement trustworthy
per-call approval and defines the smallest upstream ShellPilot contract needed
to unblock it. No approval is simulated after a Tool has run.

## Status

**Blocked on the Engine.** ShellPilot 0.4.0 can stop some Tool calls through
PowerShell `ShouldProcess`, but DeskPilot cannot safely use that mechanism as a
per-call approval protocol.

## Verified behavior

The Engine emits its structured `tool.call` event before dispatch. It then
parses and policy-checks the arguments and enters the Tool dispatch switch.
Mutating built-in Tools, MCP Tools, and User Tools call
`$PSCmdlet.ShouldProcess(...)` immediately before execution.

That is a real pre-execution boundary, but it is an interactive console
boundary rather than a host integration contract:

- `Invoke-Shp` exposes no approver callback or decision channel.
- `ShouldProcess` gives the PowerShell host an action and display target, but no
  Tool-call id, Tool class, MCP server identity, or action fingerprint.
- The MCP display target contains the raw argument JSON. Routing that text into
  DeskPilot would violate the requirement to build summaries from known fields
  and never expose secret-bearing arguments.
- MCP annotations are not carried to the confirmation boundary, so DeskPilot
  cannot distinguish a trustworthy read-only declaration from missing or
  malformed mutation metadata.
- A declined `ShouldProcess` call already becomes a recoverable Tool result,
  but DeskPilot cannot correlate that choice with a Conversation, Turn, and
  exact action before the prompt is answered.

The existing `ShpProgress` and `tool.call` records are observational. They do
not accept a response and therefore cannot be used as an approval gate.
Stopping the Engine pipeline after receiving one would cancel the whole Turn
and can race the dispatch it is intended to prevent.

## Required upstream contract

Add an optional `Invoke-Shp -ToolCallApprover <scriptblock>` parameter. Invoke
the callback synchronously after argument parsing and Tool policy evaluation,
but before `ShouldProcess` and before every Tool implementation or MCP request.
When omitted, preserve current behavior exactly.

Call the callback with one immutable object containing:

| Field | Contract |
| --- | --- |
| `CallId` | The provider Tool-call id for this iteration. |
| `Name` | The exact Tool name offered to the Model. |
| `Class` | One narrow class: `Terminal`, `FileWrite`, `Mcp`, or `UserTool`. |
| `ArgumentsJson` | The original argument JSON for host-side allow-list summarization; never logged by the Engine. |
| `Fingerprint` | A lowercase SHA-256 digest over the Tool name, call id, and exact argument bytes. |
| `McpServer` | The attached server name for an MCP Tool; otherwise null. |
| `McpTool` | The server-local MCP Tool name; otherwise null. |
| `McpAnnotations` | Validated MCP annotations plus a flag stating whether the server supplied a well-formed annotation object. |
| `Policy` | The Engine policy result (`allowed` or `denied`) and its reason. |

The Engine must preserve the distinction between absent, malformed, and valid
MCP annotations. A valid boolean `readOnlyHint: true` declares a read-only
call. `false`, absent, malformed, or ambiguous metadata must be treated as
potentially mutating by the host. Other hints can inform the risk description,
but must not turn a potentially mutating call into a read-only call.

The callback returns one object:

```text
@{
    Allowed = $true | $false
    Code    = 'approved' | 'user_denied' | 'stale' | 'cancelled'
    Message = '<bounded, non-secret Tool result message>'
}
```

The Engine owns these invariants:

1. It never dispatches the Tool before the callback returns `Allowed = $true`.
2. A callback exception fails closed and becomes a recoverable denied Tool
   result; it does not execute the Tool or terminate the Turn.
3. `Allowed = $false` appends a structured Tool result to the conversation and
   lets the Model recover or choose another action.
4. The callback runs for every Terminal command, file write or directory
   creation, MCP call, and User Tool before the existing `ShouldProcess` gate.
5. Engine Tool policy remains authoritative. The callback cannot override a
   policy denial or make a disabled Tool available.
6. Pipeline cancellation interrupts a blocked callback and no Tool dispatch
   occurs afterwards.
7. Raw arguments and callback objects are not written to verbose output,
   progress events, Usage records, or exception messages.

DeskPilot, not the Engine, will decide whether a call needs approval, maintain
Turn-scoped approval for one Tool class, build redacted action summaries,
correlate the request with the Conversation and Turn, and deliver the request
through the existing pending-request pump. This keeps product policy out of
ShellPilot while giving the Host Server a synchronous pre-dispatch boundary.

## DeskPilot implementation gate

Do not add an approval surface, approval routes, Activity records, or approval
state until an imported Engine exposes `ToolCallApprover` and a focused
integration test proves all of the following:

- the callback is entered before a Terminal side effect;
- denial prevents the side effect and reaches the Model as a Tool result;
- cancellation releases a blocked callback without dispatch;
- MCP annotation validity and provenance reach the callback unchanged; and
- a policy-denied or category-disabled Tool cannot be approved by the callback.

Once that gate passes, implement the DeskPilot behavior test-first using the
same bridge and pending-request pump as Ask-User.
