# Per-call approval Engine contract

DeskPilot owns approval policy and its user interface. ShellPilot owns the
pre-dispatch decision point. An Activity event is observation, never authority.

## Current supported interfaces

The primary interface is ShellPilot `ToolCallControl` schema 1, verified against
`ai/agent-modernization` at `08a4a22e07cb5887996bc4262c638b360f5de74e`.
The earlier `ToolCallApprover` proposal remains a supported legacy adapter; it is
not a request for upstream to duplicate its now-existing control interface.

`approvalCoverage` defaults to `terminal`. Explicit `mutating-tools` coverage is
active with Local per-call approval or Isolated Terminal. It does not enable a
Permission, change isolation, enable a child, or replace the default Engine.
Neither recognized interface means the Turn is refused before Tool setup or any
provider request. The recognized parameter type must match its contract.

## Modern pre-call control

DeskPilot binds `ToolCallControl` with `SchemaVersion = 1`, a Runspace-owned
`PreToolCall`, a Host policy identifier and explicit `FailPosture = 'Closed'`.
No post-call hook or argument modification is used. The hook is called only
after ShellPilot policy has allowed the Tool; it may narrow that decision only.

| Engine field | Host interpretation |
| --- | --- |
| `SchemaVersion`, `Phase` | Require numeric 1 and `Pre`; unknown shapes deny. |
| `Tool`, `Origin`, `Trust` | Verify origin/provenance, then classify File changes, native Terminal, User Tools and MCP. Unknown built-ins deny. |
| `ToolCallId`, `RunId`, `TurnId`, `RequestId` | Bind the approval to this exact Engine request and Host Conversation/Turn. |
| `EffectiveArguments` | Validate bounded JSON object bytes and bind these bytes, never earlier `OriginalArguments`. |
| `Server` | Require the exact MCP alias captured from current registrations. |

The adapter translates a positive Host decision to `Decision = 'allow'` and
all other results to `Decision = 'deny'` with a bounded reason. Exceptions or
invalid responses remain closed at the Engine. It never returns `modify` and
never executes a Tool itself. The separate Engine `ExecutionContract` is an
execution/containment seam, not a substitute approval callback.

The Host computes its action fingerprint from effective arguments, exact Tool
identity and correlated scope. It does not expect request hashes that the Engine
only places on its later decision receipt. `Policy.Allowed = true` in the
internal legacy-shaped adapter is derived from the documented Pre-hook ordering,
not accepted from Model content.

## MCP identities and conservative approvals

Every MCP call is approved once. Read-only annotations do not bypass a prompt;
missing annotations therefore do not block this conservative integration.

Namespaced names can replace punctuation and truncate with a digest. DeskPilot
never reverses them to guess a server-local name. At Turn setup it captures the
Engine's registration mapping (`Name`, server alias, `OriginalName`) for Ready
servers, bounded to 4,096 Tools. Duplicate, malformed or unavailable identities
fail closed. The request alias must match the frozen record before the original
Tool identity appears on the approval card. This adapter depends on the pinned
Engine registration shape; compatibility tests must accompany Engine updates.

MCP schemas, annotations and results remain untrusted data. Approval does not
sandbox a server process or confine what it can do with its own credentials.

## Legacy callback

A legacy Engine can expose `Invoke-Shp -ToolCallApprover <scriptblock>`. It must
call after policy validation and before execution, passing `Name`, `Class`,
`CallId`, `ArgumentsJson`, a request `Fingerprint` and boolean `Policy.Allowed`.
MCP additionally needs `McpServer` and server-local `McpTool`. DeskPilot returns
`Allowed`, `Code` and `Message`. Missing or string-typed policy booleans deny.
The legacy path retains the same once-only, revocation and scope guarantees.

## Permissions, scope and cancellation

- File changes require File Permission; an owned User Tool that edits also
  requires User Tools Permission. Native Terminal is disabled when owned approval
  is active; the model cannot bypass the owned gate by naming the native Tool.
- Known read-only built-ins and DeskPilot-owned read/question Tools retain
  category policy. Other User Tools and every MCP call require approval once.
- File/MCP/User Tool cards show known destination/operation fields, never file
  bodies or arbitrary arguments. Full bytes are still fingerprint-bound.
- Ordinary Terminal keeps explicit once/Turn grants under decision 0011.
  Other classes cannot inherit these grants.
- Stop, completion and relevant Permission/Project/coverage changes revoke the
  bridge. Revocation does not undo an effect already admitted.

## Disabled-Terminal behavioral proof

Local registration and Isolated readiness use the same bounded proof, not a
source identifier or version comparison. A separate Runspace imports the Engine
and exercises two scripted Turns: a disabled native call must be denied with
zero executor calls; an enabled positive control must reach the inert executor
once. No Model or real command runs, and the active Engine Runspace is untouched.

Modern Engines use `RequestTransport` and `ExecutionContract`. Supported older
Engines use the retained synthetic transport/executor seams in the isolated
probe, with HTTP paths refused. Results are cached by module path, file bytes
and loaded command digest; changed bytes invalidate the cache. A failed or
unavailable proof refuses Terminal setup rather than guessing enforcement.

## Validation and rollback

Tests cover both control vocabularies, effective-action fingerprints, MCP
punctuation-preserving identities, denial, cancellation, category revocation,
unknown shapes and non-enforcing negative controls containing the old marker.
CI builds the pinned compatibility Engine and uses it on Windows, macOS and
Ubuntu, rather than allowing dispatch tests to skip based on source text.

Fixtures prove dispatch and Host integration, not live provider behavior or
kernel isolation. See [Engine compatibility](../docs/engine-compatibility.md).
Return coverage to `terminal` for the earlier profile; restart the Host Server
after an Engine update. Source-bound child proofs remain invalidated by changes
and no parallel topology is enabled.
