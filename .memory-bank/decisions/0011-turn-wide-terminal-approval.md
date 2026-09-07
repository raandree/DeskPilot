---
schema-version: 1
status: accepted
owner: software-engineer
last-verified: 2026-09-07
source: explicit operator request and scoped approval regression tests
---

# 0011 - Turn-wide Terminal approval

This amendment records the operator's explicit 2026-09-07 request to enable
**Allow for this Turn**. It supersedes decision 0008's no-Turn-grant rule for
ordinary Local and Isolated Terminal commands only.

## Contract

The window offers **Allow once**, **Allow for this Turn**, and **No** for an
eligible Terminal approval. Omitted scope remains `once`. A Turn grant is an
explicit acceptance that later commands in the same scope can run without
another question; it is not permission for all future work.

The approval bridge retains one in-memory grant bound to the Terminal Tool,
Conversation, Turn, Project, working directory, and frozen execution policy.
The scope digest excludes command text so later different commands can use it.
The initial approval remains correlated to the exact pending request. Invalid
scope types, stale requests, cross-Conversation replies, or non-Terminal classes
cannot create the grant. A new scope requires a new explicit approval.

Stop cancels even while no question is waiting. End/failure and the next Turn
clear the grant. Live Terminal/User Tools Permission revocation, approval-mode
changes, or Project/execution-policy changes cancel the approval bridge and
require a new Turn. Unrelated Settings edits do not revoke it. Existing running
commands retain their execution boundary; this is not retroactive rollback.

Activity records requested/approved/denied status, once/turn scope, approval
source, and time without command arguments. Grant state is not persisted.

## Preserved boundaries

- Category and Engine Tool policy remain authoritative.
- The grant never changes isolation, mounts, network, credentials, or limits.
- Browser and child approvals remain action-scoped. Child V2/V3 and parallel
  topology decisions are not amended; parent grants cannot be inherited.
- Intercom can still approve once or deny, but cannot create a Turn grant.
- Native File writes and MCP calls still require specification 120.
- Existing `perCallApproval` and Terminal defaults are unchanged. Each new Turn
  starts without a grant; nothing is automatically approved by this amendment.

## Risks and rollback

In Local mode, approved Terminal commands run with the user's account and can
affect files/network beyond the working directory. Turn scope is an approval
scope, not filesystem confinement. The visible warning makes the broader
authorization explicit. An injected Agent can misuse that authority until it is
revoked. Isolated mode retains its existing lower-level controls.

Use **Allow once** to retain prior behavior. Stop the Turn to revoke a grant.
Restart the Host Server after updating its bridge implementation. Any Host
source change invalidates prior source-bound child proof; re-prove before child
enablement. Independent review is recommended for this authorization change.
