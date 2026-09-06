---
schema-version: 1
status: accepted
owner: shared
last-verified: 2026-09-06
source: repository implementation and decision records
---

# System patterns

## Architecture map

- **Engine ownership.** ShellPilot owns provider transport, authentication,
  Models and Usage. DeskPilot owns the Host Server, policy and presentation.
- **One Engine Runspace.** A fresh PowerShell pipeline runs each Turn on one
  long-lived Runspace. Tool registration and globals are Runspace-local;
  environment and process working directory are process-global. Set only the
  Runspace location; do not use process-global mutation for Turn context.
- **Conversation history.** Visible Messages and replay history stay separate.
- **Streaming.** Information records drive SSE and ordered Activity. Provider
  content is authoritative final text. Structured pre-execution Activity prevents
  unsafe retries but is not approval; it has no decision response channel.
- **Single accept loop.** Pending requests are pumped during a Turn so Stop and
  approval answers work. Slow setup and checks run outside that loop.
- **Static UI.** Bundle vanilla assets with CopyPaths; reuse existing UI patterns.

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

## Execution and approval

- **Own the Tool and prove dispatch.** Disable the native Terminal and register
  `run_terminal_command`, never a built-in name. ShellPilot dispatches built-ins
  before User Tools. Test the Engine itself: removing an offered schema alone
  does not prove disabled calls cannot execute. Probe enforcement and fail closed.
- **Approval precedes effects.** The bridge blocks before the executor. A
  safe-list handles routine reads; everything else is individually approved.
  Bind command, working directory, Conversation, Turn and execution policy. No
  Turn-wide grants. Secret values and Model-authored justifications are absent.
- **No silent Local fallback.** Isolated mode owns Terminal even with Local
  approval off. Permission/dependency failures refuse work. Freeze each Turn's
  policy and render the recorded boundary, not later Settings edits.
- **Containment is below the Model.** Narrow mounts and empty ambient identity
  remove host-data access; default-deny egress removes arbitrary outbound access.
  Output is untrusted Tool data. Other enabled Tools retain their own authority.
- **HTTPS is not host:443.** Require CONNECT or an encrypted HTTPS request.
  Inspect client TLS before upstream contact and authorize HTTP authority first.
  Namespace packet rules still deny direct sockets/DNS if proxy variables vanish.
  A remote 400 or failed TLS handshake is not proof of pre-egress denial.
- **Whole-environment lifecycle.** Stop removes command and proxy containers,
  not only Docker CLI processes. Proxy failure terminates its command. Verify
  cleanup; incomplete cleanup remains visible and prevents further isolated work.
- **Prepared runtime.** Explicit setup verifies bytes, records package/source
  provenance and immutable image identity. Turns use prepared images only.
  Runtime source changes invalidate preparation; do not edit during a proof run.

## Data, changes and diagnostics

- **Hardened command runner.** Git uses a separate argument list, closed stdin,
  disabled terminal prompts, literal pathspecs, deadline-bounded asynchronous
  output and process-tree termination. Every local command can still run hooks.
- **Project-relative paths.** Rebase Git repository paths to the selected Project;
  reject lexical escapes and links at file boundaries. Never infer containment
  from a shared prefix, and never follow unknown archive or mount aliases.
- **Pending changes are not Git status.** Pre-Turn snapshots use a throwaway
  index. Keep accepts; Save commits; Undo restores the original tracked snapshot
  while preserving earlier user edits. Do not wrap Get-DpChangeEntry's intact
  array in another array at route boundaries.
- **Structural redaction.** Diagnostics and Support bundles project allow-listed
  fields into new objects; never serialize live state and scrub afterward.
  Self-checks do not call a Model. Host logs are bounded, transient and redacted.
- **Unknown is not zero.** Usage comes only from the Engine. Missing pricing and
  partial Stop estimates stay explicitly labeled; fixture Usage is not billing.
- **Scope can only narrow.** Scheduled and Intercom work reuse the Turn dispatcher.
- **Untrusted content.** Attachments, files, pages, Tool results and recalled
  Memory never become user-authored instructions or policy.

## Validation and retained detail

Use test-first changes and real positive/negative security controls. Full HTTP
tests catch StrictMode and array-shape gaps. Detach Pester/Sampler and keep logs
outside build output. Keep review, local tests, live authentication, and released
dependencies as separate gates. Documentation checks are not new executable runs.

Detailed patterns, browser and Intercom history, and caveats are preserved in
[system-patterns-2026-09-05.md](archive/system-patterns-2026-09-05.md). Read its
relevant section only when a task needs deeper implementation detail.
