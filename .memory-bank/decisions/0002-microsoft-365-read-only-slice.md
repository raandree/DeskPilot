---
schema-version: 1
status: accepted
owner: software-engineer
last-verified: 2026-09-02
source: repository evidence
---

# 0002 — Microsoft 365 read-only slice: contract recorded, implementation blocked

## Status

**Contract specified, implementation not started.** The prompt requires the
identity and data-flow contract to be *recorded and presented* before code; it
also requires decisions this session cannot obtain.

## Why implementation stopped

Three hard blockers, in order of severity:

1. **No application identity exists.** Delegated OAuth to Microsoft Graph needs a
   registered application (client id) and a tenant that will consent to it.
   DeskPilot has none, none can be created offline, and a client id cannot be
   invented. Every token-acquisition path — device code, authorization code with
   PKCE, broker — begins with that value.
2. **The tenant and account are unknown.** Scope minimisation is meaningless
   without knowing which tenant's policy applies (conditional access, app-consent
   restrictions, whether device-code flow is blocked outright, which it commonly
   is).
3. **No live boundary to verify against.** The prompt's own test list — consent,
   expiry, refresh, throttling, partial results, missing transcripts — can be
   *simulated*, but shipping a Graph client whose only evidence is its own fake
   would be the weakest possible release evidence for a feature that reads a
   user's mailbox.

Building against a fake boundary alone would produce a large, plausible, wholly
unverified surface touching mail and calendar data. That is the wrong trade.

## The contract, for when those are available

**First workflow.** Meeting briefing, read-only: for one calendar event in a
named window, retrieve the event, its attendees, the mail thread it references,
and the Teams transcript when one exists, and return them as *sources* the Turn
may cite.

**Identity.**

- Delegated access only. No application permissions, ever, in this slice.
- Authorization-code flow with PKCE against a loopback redirect, matching
  DeskPilot's existing loopback-only posture. Device code is the fallback where
  tenant policy permits it.
- Scopes, minimum viable and no more: `Calendars.Read`, `Mail.Read`,
  `OnlineMeetingTranscript.Read.All` only when a transcript is actually
  requested, `User.Read`, `offline_access`.
- Refresh tokens live in the **existing Secret store** (DPAPI, the
  `intercom.secret` pattern), never in `settings.json`, never in Conversation
  history, Activity, or a support bundle.
- The connected organisation and account are displayed before any Turn may use
  the connection. Disconnect deletes the local credential and is offered next to
  the account.

**Permission.** A separate `microsoft365` category Permission, off by default.
Disabling it **removes the Tools from the Turn**, exactly as the existing
categories do — never a prompt asking the Model not to call them.

**Data flow.** Local Host Server → Microsoft Graph (HTTPS, delegated) → allow-
listed fields → Turn system prompt as *fenced data, not instructions* → Model
provider. Every retrieved item carries `{ id, subject/title, webUrl,
lastModified, accessStatus }` so a generated claim is traceable. Bodies are
bounded; attachments are not downloaded in this slice.

**Untrusted by construction.** Mail bodies, chat messages, transcripts, file
names and links are data. They may not choose a Tool, a file path, or an
outbound destination. Nothing in this slice sends, replies, posts, shares,
grants, creates or deletes.

**Naming.** This is a Microsoft Graph integration and is named as one. It does
not borrow a Microsoft product or service name it does not actually integrate.

**Refused surfaces in slice one.** Scheduled use and Intercom use are refused
outright: an unattended or remote Turn reading a mailbox needs the approval
contract that does not exist yet.

## Prerequisites

1. An application registration (client id) and the tenant that will consent.
2. A test account with non-sensitive mail and calendar data.
3. A decision on whether to use a governed Microsoft-published MCP server rather
   than a direct Graph client — the prompt asks for whichever is the smaller
   auditable surface, and that comparison needs the server's actual tool list.
