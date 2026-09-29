# Engine compatibility and approval coverage

DeskPilot keeps provider transport, authentication, Models and pricing in
ShellPilot. An interface declaration, an offline fixture and a live acceptance
run are different kinds of evidence. None silently substitutes for another.

## Broader approval coverage

Terminal execution Settings offer two coverage choices:

- **Terminal only** preserves the previous behavior and remains the default.
- **Terminal, File changes, MCP and User Tools** requires the Engine's
  typed `ToolCallControl` contract or legacy `ToolCallApprover`. The option is
  unavailable when neither is recognized. Selecting it through the API on an
  unsupported Engine refuses the Turn before Tool setup or provider activity.

Coverage takes effect when Local approval is enabled or Isolated Terminal
requires approval. It does not enable a Permission, install an Engine, change
the Terminal execution boundary, or enable a child Agent. Terminal additionally
needs User Tools for DeskPilot's owned gate; there is no native fallback.

Modern controls run only after the Engine has permitted the Tool. Legacy
callbacks must report a positive boolean policy decision. Both require the
corresponding Host Permission. Native File changes, every MCP call and other
User Tools receive once-only approvals. Known DeskPilot-owned read/question Tools
retain their existing category controls; the owned Terminal Tool retains its
separate once/Turn grant semantics. Unknown or malformed metadata fails closed.

Cards show known destinations and operation identities, not complete file bodies
or arbitrary MCP argument values. A Host digest binds the full argument JSON,
Engine call identity and frozen context so identical-looking cards cannot spend
one answer on different actions. MCP annotations, Skills and recalled Memory
cannot grant authority. Approval is not filesystem or network containment.

Stop, Turn completion and relevant scope/Permission changes revoke the bridge.
Revocation does not undo an effect that already started. Returning coverage to
`terminal` restores the earlier profile without a data migration.

ShellPilot `ai/agent-modernization` at
`08a4a22e07cb5887996bc4262c638b360f5de74e` provides `ToolCallControl`. DeskPilot now
translates its schema-1 Pre request and allow/deny response vocabulary, binds
effective argument bytes, and explicitly selects closed failure posture. This
is not a parameter alias. The older installed 0.4.0 remains unsupported for
broader approval; no default installation is changed automatically.

For MCP, the original Tool identity is captured from the Engine registration
record rather than guessed from the namespaced name. Every call prompts, so
annotations are not required to waive prompts: none are waived. Missing or
ambiguous identities deny. An unavailable or incompatible registration catalog
refuses approval setup with an Engine compatibility error before dispatch,
rather than silently denying every MCP call later. A valid empty catalog is
supported when no MCP servers are registered. See the exact
[adapter contract](../specs/120-per-call-approval-engine-contract.md).

Local and Isolated Terminal checks now execute a bounded behavioral proof in a
separate Runspace. It requires both disabled-call refusal and a positive inert
executor control, without a provider or real command. The result is cached by
module bytes and loaded command identity; an internal variable rename cannot
disable the feature or skip its tests. Unsupported or failed probes remain
fail-closed and never change the active Engine's Tool state.

CI builds this immutable compatibility Engine and runs the same tests on each
OS alongside the ordinary dependency tests. To exercise it locally, set
`DESKPILOT_TEST_ENGINE_PATH` to the built ShellPilot manifest before the normal
test command. Without that explicit fixture, the separately labelled modern
integration tests are unavailable, not evidence of provider compatibility.
These tests exercise actual Engine dispatch with scripted provider responses,
not paid live Model requests. They do not prove kernel isolation or billing.

## Copilot SDK feasibility result

GitHub announced SDK general availability on
[2026-06-02](https://github.blog/changelog/2026-06-02-copilot-sdk-is-now-generally-available/).
A separate temporary installation was tested on 2026-09-24. It was not added to
DeskPilot's runtime dependencies and no provider backend was replaced.

| Observation | Result |
| --- | --- |
| SDK package | `@github/copilot-sdk` 1.0.14 |
| Test runtime | Node.js 25.6.0 on Windows |
| SDK-managed runtime | 1.0.85, explicit stdio transport |
| Connectivity | Startup, documented ping response and status query passed |
| Cleanup | Normal SDK shutdown reported no errors; owned temporary data removed |
| Agent activity | Zero sessions created and zero generation requests |
| Model transport | HTTP/WebSocket handler refused generation traffic; no such request occurred |
| PowerShell adapter, approvals, Usage and MCP parity | Not tested by this probe |

The SDK's runtime protocol number was 3. This is **not** an MCP revision or proof
of MCP interoperability. The probe corrected an initial unsupported assumption
that ping must echo its input exactly; it validates the SDK's documented
message/timestamp response instead.

A future Engine adapter must preserve authentication, streaming, Stop, Tool
policy, complete request admission, unknown/estimated Usage, Vision and
Customization behavior. Prefer a supported SDK API over an assumed-stable raw
wire protocol. Do not switch an existing installation merely because startup
works. The inspected SDK hooks include experimental surfaces; the SDK's GA
status does not make every individual feature stable.

## MCP compatibility audit

The [2026-07-28 revision](https://modelcontextprotocol.io/specification/2026-07-28/changelog)
changes initialization, per-request metadata, HTTP sessions and resumption.
DeskPilot already projects the Engine's transport, era and protocol-version
metadata, and the inspected current ShellPilot source contains modern discovery
with legacy fallback. That is not evidence that an installed older package
supports it. Missing metadata stays unknown.

Protocol implementation belongs in the Engine. No separate MCP stack, silent
upgrade, or change to DeskPilot's browser REST/SSE transport is introduced here.
Use the protocol's dual-era compatibility matrix and real server fixtures when
accepting an Engine update. Long-running MCP Tasks, automatic action replay and
parallel Agents are not enabled by this work.

## See also

- [Diagnostics and Support bundle](diagnostics-support-bundle.md)
- [Single-child V3](single-child-v3.md)
- [Security model](../specs/050-security-model.md)
