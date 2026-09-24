---
schema-version: 1
status: accepted
owner: shared
last-verified: 2026-09-24
source: repository implementation, regression evidence, and decision records
---

# System patterns

## Architecture

- ShellPilot owns provider transport, authentication, Models and Usage;
  DeskPilot owns the Host Server, policy and presentation. Probe capabilities,
  not version strings, and distinguish declarations from live enforcement proof.
- Each Turn uses a fresh pipeline in one Engine Runspace. Tool state is scoped
  there; process environment and working directory are not isolation boundaries.
- Keep visible Messages separate from replay history. Information records drive
  SSE/Activity; provider content is final. Activity is never an approval channel.
- Pump Stop and answers during Turns. Keep slow probes off the accept loop;
  bundle the static UI with CopyPaths and reuse existing controls.

## Decision index

| Record | Subject |
| --- | --- |
| [0001](decisions/0001-isolated-tool-execution.md) | Isolated Terminal |
| [0002](decisions/0002-microsoft-365-read-only-slice.md) | Microsoft 365 read-only slice |
| [0003](decisions/0003-playwright-browser-automation.md) | Contained browser |
| [0004](decisions/0004-condition-triggered-automation.md) | Condition-triggered work |
| [0005](decisions/0005-parallel-agents.md) | Parallel Agents, still proposed |
| [0006](decisions/0006-windows-packaging.md) | Windows packaging |
| [0007](decisions/0007-localization.md) | Localization |
| [0008](decisions/0008-per-call-approval.md) | Individual approvals |
| [0009](decisions/0009-single-child-isolation.md) | Single-child V2 |
| [0010](decisions/0010-child-budget-estimates.md) | V3 provider estimates |
| [0011](decisions/0011-turn-wide-terminal-approval.md) | Ordinary Terminal Turn grants |

## Execution and authority

- Disable native Terminal before registering the owned Tool; hidden schemas are
  not dispatch enforcement. Missing isolation dependencies never select Local.
- Approvals precede effects and bind exact actions, Conversation, Turn, Project,
  directory and frozen policy. Terminal Turn grants are explicit; File/MCP,
  browser and child grants remain once-only. Stop/end/scope changes revoke them.
- Broader coverage requires the Engine contract in specification 120. Metadata,
  MCP hints, Skills, recalled Memory and observed Activity grant no authority.
- Terminal isolation does not isolate File/MCP or process-global state. Narrow
  mounts, identity and egress below the Model; untrusted outputs remain data.
- Authorize network contact first: require CONNECT/encrypted HTTPS, verify TLS
  and authority, and deny direct sockets/DNS regardless of proxy variables.
- Stop admission independently of blocked IPC; use one nonextendable cleanup
  deadline. Incomplete cleanup stays visible and blocks further isolated work.
- Bind readiness to immutable image/source/assembly identities, real process
  readiness and verified lifecycle. Component checks do not authorize children,
  concurrency or a new egress boundary. Source changes invalidate old proof.
- Preserve prelaunch recovery identity separately from flushed state. Keep
  owned process/storage quotas, directory leases and tar draining bounded.
- Provider counts are protocol-specific. Preserve unknown reservations; V3
  estimates never become invoice caps. Match Tool names/ids across protocols and
  keep child approval tokens distinct. Structural redaction is not a secrets proof.

## Data and user experience

- Rebase paths to the Project and reject escapes/links. Skill inspection checks
  containment before I/O, with exact comparisons off Windows; metadata is inert.
- Agent Memory carries provenance and scope. Learn only from the frozen source
  Message and same-scope earlier Messages, never mutable window/Conversation state.
- Refuse over-cap mutations; report lossy imports. Preserve exact old bytes with
  create-new backup semantics before replacement; unknown verification is not true.
- Compact only replay context, not visible Messages. Coverage heuristics are not
  semantic quality grades. Gate async editor replies by the owning editor identity.
- Pre-Turn Git snapshots use a separate index. Keep accepts, Save commits and Undo
  preserve user edits. Compare normalized blobs before refreshing an index.
- Diagnostics is allow-listed and bounded; no prompts/arguments in correlation
  records. Unknown Usage stays unknown. Preserve redacted preparation errors and
  stable prerequisite identifiers; readiness evidence belongs to one machine.
- Intercom allow-lists first. Mentions address work, never authorize it; exact
  same-chat plain-text pending replies may bypass mentions. All entry points use
  the Turn dispatcher and the same Permission boundaries.
- Theme and Mode remain independent local display preferences. Bundle licensed
  fonts and check computed colors, actual fonts and control bounds.

## Validation and release

- Use test-first and real HTTP/browser checks. Keep fixtures, live Model proof
  and released dependencies distinct. Missing evidence must remain unavailable.
- Repeat isolated evaluation cases; distinguish capability from all-trials
  reliability and retain safety failures. Own temporary state before deleting it,
  reject link escapes, and surface cleanup failure rather than reporting success.
- Resolve Pester from latest and validate Pester 6. Detach Sampler/Pester with
  instrumented TEMP logs. Use `--git-dir` for bare Git fixtures, not weaker policy.
- Bind CI evidence to the pushed SHA and artifact; inspect the whole OS matrix
  and deployment condition. Compile related Add-Type sources as one guarded set.
- Earlier detail is retained in [patterns archive](archive/system-patterns-2026-09-05.md)
  and the accepted Decisions; logs never override current source.
