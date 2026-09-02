---
description: "Implement per-call approval for risky DeskPilot Tool actions"
agent: "software-engineer"
---

# Implement per-call approval

## Why this feature is useful

Category Permissions authorize a Tool for an entire Turn. Per-call approval
lets the user inspect the actual command or mutation before it happens, reducing
the gap between the capability they enabled and the action the Agent chose.

## Use case

An operations analyst enables Terminal so the Agent can inspect a service. The
Agent proposes a command that also deletes old files. DeskPilot pauses, shows the
exact command and its scope, and lets the analyst allow it once, allow Terminal
actions for this Turn, or deny it without stopping the Turn.

## Objective

Implement confirm-before-run approval for:

- Every Terminal command.
- Every file write outside the selected Project.
- Every mutating MCP call, using trustworthy MCP annotations when present and a
  conservative default when annotations are absent or ambiguous.

Do not treat approval as a replacement for category Permissions. A disabled
Permission must keep the Tool unavailable; approval applies only after its
category is enabled.

## Required context

Read these sources before changing code:

- `specs/010-requirements.md`
- `specs/020-architecture.md`
- `specs/030-api-contract.md`
- `specs/040-ui-design.md`
- `specs/050-security-model.md`
- `specs/060-roadmap.md`
- `.memory-bank/systemPatterns.md`
- `.memory-bank/glossary.md`

Trace the Engine's structured Tool-call progress path, Ask-User pending-request
path, Stop handling, Intercom question delivery, and Tool result/error path.
Confirm whether the Engine can block execution before each target Tool runs. If
it cannot, stop and document the smallest upstream Engine contract required;
do not simulate approval after an action has executed.

## Required behavior

- Show the Tool, bounded action details, affected Project or destination, and a
  plain-language risk description without exposing secret values.
- Offer `Allow once`, `Allow for this Turn`, and `Deny`.
- Scope Turn-wide approval to the narrow Tool class being requested. Never turn
  one approval into a persistent wildcard policy.
- Treat denial as a structured Tool result the Agent can recover from. Do not
  fail or cancel the entire Turn unless the Engine contract requires it.
- Keep Stop responsive while approval is pending.
- Route approval through the pending-request pump used by Ask-User so the one
  Engine Runspace and one-active-Turn architecture remain intact.
- Deliver and accept approval through Intercom only if the Channel can present
  the same action detail and caller authority is sufficient. Otherwise direct
  the user to DeskPilot without silently approving or denying.
- Record requested, approved, and denied actions in Activity. Store the choice,
  scope, timestamp, and safe summary; never store raw secrets.
- Invalidate all Turn-scoped approvals when the Turn completes, fails, or is
  stopped.
- Default missing MCP mutation metadata to approval required.

## Security boundaries

- Build action summaries from an allow-list of known fields. Unknown Tool
  arguments contribute only Tool identity and bounded metadata.
- Never include environment-variable values, authorization headers, tokens,
  credentials, or full file bodies in the approval surface or logs.
- Resolve and compare file paths on the Host Server. Handle symlinks, junctions,
  case-insensitive paths, UNC paths, and paths that do not exist yet.
- Prevent replay: correlate each answer with one Conversation, Turn, request,
  and action fingerprint.
- Deny stale answers after Stop, completion, Project changes, or request expiry.
- Preserve the current default that Terminal Permission is off.

## Test-first proof

Write failing Pester tests before production changes. Cover at least:

- Terminal approval blocks execution until answered.
- Allow once authorizes exactly one matching action.
- Allow for this Turn does not authorize a different Tool class or later Turn.
- Denial prevents the side effect and returns a usable result to the Agent.
- An outside-Project write requires approval; an inside-Project write follows
  the existing File Permission and pending-change flow.
- Missing or malformed MCP annotations require approval.
- Stop works while approval is pending and invalidates a late answer.
- A stale or cross-Conversation answer cannot approve an action.
- Secret-bearing arguments are redacted from the UI, Activity, and transcript.
- Intercom cannot widen approval authority.

Include paired positive and negative assertions so a test cannot pass because
the target branch was never reached. Run focused tests after the first change,
then the full Sampler build and test gate.

## Definition of done

- Update requirements, API contract, UI design, security model, and roadmap with
  the implemented contract and explicit failure states.
- Keep the SPA build-free and preserve existing category Permission behavior.
- Add accessible keyboard and screen-reader behavior for the approval surface.
- Preserve Activity, Usage, pending changes, Checkpoints, Stop, and Intercom.
- Run PowerShell parsing, PSScriptAnalyzer, JavaScript syntax checking when the
  SPA changes, focused Pester tests, and `./build.ps1 -Tasks build, test`.
- Update `CHANGELOG.md` and the routed Memory Bank records.
- Commit on a focused topic branch. Do not push.

## Non-goals

- A permanent allow/deny policy editor.
- Automatic approval based on Model reasoning.
- Approval after a Tool has already run.
- OS-level isolation or a replacement Engine.