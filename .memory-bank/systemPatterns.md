---
schema-version: 1
status: accepted
owner: shared
last-verified: 2026-09-08
source: repository implementation and decision records
---

# System patterns

## Architecture map

- ShellPilot owns provider transport, authentication, Models, and Usage;
  DeskPilot owns the Host Server, policy, and presentation.
- Initialization can return an undecoded credential. Prove authentication with
  an Engine operation; separate decryption failures from provider rejection.
- Each Turn uses a fresh pipeline in one Engine Runspace. Tool state is local
  to that Runspace; environment and process working directory are not.
- Keep visible Messages separate from replay history. Information records drive
  SSE/Activity; provider content is final. Activity is not an approval channel.
- Pump requests during Turns for Stop and answers; keep slow checks outside the
  accept loop. Bundle the static UI with CopyPaths and reuse existing controls.

## Decision index

| Record | Subject |
| --- | --- |
| [0001](decisions/0001-isolated-tool-execution.md) | Optional isolated Terminal execution |
| [0002](decisions/0002-microsoft-365-read-only-slice.md) | Microsoft 365 read-only slice |
| [0003](decisions/0003-playwright-browser-automation.md) | Contained browser automation |
| [0004](decisions/0004-condition-triggered-automation.md) | Condition-triggered work |
| [0005](decisions/0005-parallel-agents.md) | Parallel Agents |
| [0006](decisions/0006-windows-packaging.md) | Windows packaging |
| [0007](decisions/0007-localization.md) | Localization |
| [0008](decisions/0008-per-call-approval.md) | Individual Terminal approvals |
| [0009](decisions/0009-single-child-isolation.md) | Approved single-child V2 and partial storage implementation |
| [0010](decisions/0010-child-budget-estimates.md) | Accepted V3 provider estimates with unchanged isolation and hard local bounds |
| [0011](decisions/0011-turn-wide-terminal-approval.md) | Explicit ordinary Terminal Turn grants and live scope revocation |

## Execution and approval

- **Prove dispatch.** Disable native Terminal and register
  `run_terminal_command`; hiding a schema alone is not enforcement.
- **Approval precedes effects.** Ordinary Terminal grants bind to Conversation,
  Turn, Project, directory, Tool/class, and frozen policy. Stop, completion, and
  window/Intercom scope changes revoke them. Browser/child grants stay once-only.
- **Preserve scope.** Read scalar scope without array-unwrapping helpers.
  Approval Activity projects allowed metadata, never complete arguments.
- **No Local fallback.** Isolated mode owns Terminal; missing dependencies or
  Permissions refuse work. Freeze and display the recorded execution policy.
- **Contain every Tool.** Terminal isolation alone does not confine File Tools
  or process-global state. Narrow mounts, identity, and egress below the Model.
- **Authorize before contact.** Require CONNECT or encrypted HTTPS, verify TLS
  and HTTP authority, and deny direct sockets/DNS regardless of proxy variables.
- **Stop independently.** Close admission atomically despite blocked IPC. Remove
  owned commands/proxies/containers within one shared, nonextendable deadline.
  Incomplete cleanup stays visible and blocks further isolated work.
- **Prove prepared bytes.** Record immutable image, source, and loaded assembly
  identities. Runtime changes require restart and a fresh actual-launch proof.
- **Preserve recovery identity.** Keep immutable prelaunch identity separate
  from flushed state; Windows directory handles also block child-file rename.
- **Verify lifecycle.** Require authenticated process readiness, not Docker
  `wait` on a merely created container. Drain bounded tar padding before waiting.
- **Separate proofs.** Component checks do not prove a complete child profile,
  approve downstream concurrency, or authorize a new Tool/egress boundary.
- **Counting is provider-specific.** Compare exact request shapes with Engine
  Usage. Fixture counts or observed overcounts prove no hard bound; retain
  unknown reservations. V3 estimates require the explicit decision 0010 contract.
- **Preserve correlation.** Require exact Tool-result name/id agreement across
  Chat and Messages. Child approval identifiers must not reuse Host Server tokens.
- **Normalize credential fields structurally.** Traverse objects/arrays and
  normalize separators; matching field names cannot prove content secret-free.

## Data, changes and diagnostics

- Compare normalized Git blobs before refreshing content-identical index entries;
  never discard edits. Commands use literal arguments, closed stdin, and deadlines.
- Rebase paths to the Project; reject escapes, links, and unknown mount aliases.
- Pre-Turn snapshots use a separate index. Keep accepts, Save commits, and Undo
  preserves user edits. Do not rewrap intact change arrays at route boundaries.
- Diagnostics projects allow-listed fields. Self-checks call no Model; logs are
  bounded/redacted. Unknown Engine Usage remains unknown, not zero or billing.
- **Intercom addressing is not authority.** Allow-list first; optionally require
  exact Telegram text/caption mention entities before effects. Direct plain-text
  pending answers also qualify by positive Message id and exact nonempty chat
  binding, even with unknown identity. Commands, edits, and Attachments do not.
  Private Messages and validated Keyboard callbacks are unchanged.
  Mentions grant no Permission. Scheduled/Intercom work reuses the Turn dispatcher.
- Attachments, files, pages, Tool results, and recalled Memory are untrusted data.

## Validation and retained detail

Use test-first and real HTTP checks. Detach Pester/Sampler; retain logs outside
build output. Keep review, local tests, live proof, and released dependencies
separate. Consult accepted Decisions and [earlier patterns](archive/system-patterns-2026-09-05.md) for detail.
