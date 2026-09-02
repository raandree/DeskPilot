---
description: "Implement consent-gated Microsoft 365 work integration for DeskPilot"
agent: "software-engineer"
---

# Implement Microsoft 365 work integration

## Why this feature is useful

Knowledge work often spans mail, calendars, meetings, tasks, and shared files.
A governed Microsoft 365 connection would let DeskPilot assemble that context
without manual exports while preserving visible sources, approvals, and Activity.

## Use case

Before a project review, an analyst asks DeskPilot to find the relevant Outlook
messages, calendar events, Teams meeting transcript, and OneDrive documents,
then draft a cited briefing in the selected Project. DeskPilot reads only data
the signed-in user can access and does not send, share, or change anything.

## Objective

Implement one read-only Microsoft 365 workflow with explicit account consent,
least-privilege scopes, source provenance, and revocation. Treat mutating actions
as a later approval-gated slice.

## Required context

Read `specs/010-requirements.md`, `specs/020-architecture.md`,
`specs/030-api-contract.md`, `specs/040-ui-design.md`,
`specs/050-security-model.md`, `specs/060-roadmap.md`, and the authentication,
MCP, Permission, Activity, Usage, Secret, and Intercom patterns in
`.memory-bank/systemPatterns.md`. Trace the Engine Tool registration boundary and
determine whether an existing governed MCP server or a direct Microsoft Graph
client provides the smaller auditable surface.

## Specify before implementation

Record and present a concrete contract for:

- The first supported workflow and Microsoft 365 resources it reads.
- Delegated identity, tenant restrictions, OAuth flow, scopes, token storage,
  refresh, expiry, sign-out, revocation, and account switching.
- Source links, timestamps, sensitivity labels, and stale or partial results.
- Permission mapping between Microsoft 365 operations and DeskPilot Permissions.
- Data sent through the Engine and third-party Models after retrieval.
- Interactive, scheduled, and Intercom behavior.

Do not call a Microsoft Graph implementation Work IQ. Use that name only if the
product integrates with Microsoft's documented Work IQ service and contract.

## Required behavior

- Begin with one read-only scenario, such as a meeting briefing from Outlook,
  calendar, and an available Teams transcript.
- Use delegated access and the smallest scopes needed for that scenario.
- Show the connected organization and account before each Turn can use it.
- Add a separate Microsoft 365 Permission; disabling it removes the Tools from
  the Turn rather than relying on the Model not to call them.
- Record every query in Activity without storing message bodies, tokens, or
  secrets in logs.
- Return source identity, URL when available, modified time, and access status
  with retrieved content so generated claims remain traceable.
- Distinguish not found, inaccessible, consent missing, expired, throttled, and
  service unavailable results.
- Support disconnect and revoke locally stored credentials.
- Preserve loopback-only Host Server operation.

## Security and reliability boundaries

- Store refresh tokens and equivalent credentials in the existing Secret store,
  never `settings.json`, Conversation history, Activity, or support bundles.
- Treat mail, messages, transcripts, file contents, names, and links as untrusted
  data rather than Instructions.
- Prevent retrieved private data from authorizing Tool calls or choosing an
  outbound destination.
- Do not send, reply, post, share, grant access, create events, or change tasks
  in the first slice.
- Redact sensitive content from errors and telemetry.
- Bound pagination, retries, content size, attachment downloads, and throttling.
- Do not broaden scopes silently after an update.

## Test-first proof

Write failing Pester tests around a fake Microsoft 365 boundary. Cover at least:

- Consent, least-privilege scopes, expiry, refresh, disconnect, and revocation.
- Tenant and account mismatch behavior.
- Permission-off Tool removal and read-only enforcement.
- Pagination, throttling, partial results, unavailable transcripts, and timeout.
- Prompt-injection text in mail, Teams, transcripts, and document metadata.
- Token, body, recipient, and sensitivity-label redaction in Activity and logs.
- Source provenance in the generated briefing input.
- Scheduled and Intercom use being refused until separately approved.

## Definition of done

- Update requirements, architecture, API contract, UI design, security model,
  and roadmap with the approved identity and data-flow contract.
- Add accessible connect, account, Permission, error, and disconnect states.
- Produce a data-flow diagram and threat model for local data, Microsoft 365,
  the Engine, and Model-provider boundaries.
- Run focused tests, parsing, PSScriptAnalyzer, JavaScript syntax checking when
  applicable, and the full Sampler build and test gate.
- Update `CHANGELOG.md` and routed Memory Bank records.
- Commit on a focused topic branch. Do not push.

## Non-goals

- Claiming parity with Microsoft Scout or Work IQ.
- Application permissions, tenant-wide indexing, or administrator impersonation.
- Sending mail, posting messages, sharing files, or changing calendars and tasks.
- Storing a local copy of a mailbox, OneDrive, or Teams corpus.
- Replacing the Engine's GitHub Copilot authentication.