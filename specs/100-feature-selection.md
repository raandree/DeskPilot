# Spec 100 — Feature selection and decision gates

> Status: decision record, 2026-09-02, refreshed 2026-09-03. This spec records
> which features DeskPilot should build next and why, in terms of its own
> audience, security model and architecture. It does not add requirements by
> itself; see the [decision gate](#decision-gate).

## Decision summary

DeskPilot should not try to match the total feature count of general-purpose
agent harnesses. Its defensible position is narrower: a Copilot-native agent
for knowledge workers, with visible safety, strong change review, and
plain-language Git workflows.

The features with the strongest justification, in order:

1. **Per-call approval** for Terminal commands, file writes outside the
    Project, and mutating MCP calls.
2. **Diagnostics and support bundle**: live Host Server and Engine logs,
    environment/version checks, and a redacted export.
3. **Scheduled work**, designed around the single-active-Turn rule before it is
    implemented.
4. **Packaging and localization**, beginning with a signed or verifiable
    desktop installer and German UI resources.
5. **Optional isolated execution**, after approval is shipped: first a remote
    or container-backed Terminal boundary, not a new agent runtime.

A read-only Microsoft 365 connection and local condition-triggered automation
are two further candidates. Both follow approval; neither requires an
enterprise deployment or management model.

Parallel Agents and browser/computer automation are later bets. Both increase
the value of DeskPilot, but also multiply the consequences of its current
full-user-privilege execution model.

## Feature prompt chooser

Each candidate has an independent Prompt File under `.github/prompts`. Packaging
and localization are separate choices because they have different dependencies,
acceptance criteria, and rollback paths.

| Candidate | Selection guidance | Prompt File |
| --- | --- | --- |
| Per-call approval | Terminal shipped; file writes and MCP still need the `specs/120` contract. | [Implement per-call approval](../.github/prompts/implement-per-call-approval.prompt.md) |
| Diagnostics and support bundle | **Shipped.** | [Archived](../.github/prompts/archive/implement-diagnostics-support-bundle.prompt.md) |
| Scheduled work | **Shipped.** | [Archived](../.github/prompts/archive/implement-scheduled-work.prompt.md) |
| Windows packaging | **Shipped.** | [Archived](../.github/prompts/archive/implement-windows-packaging.prompt.md) |
| Localization | **Shipped** (English + German). | [Archived](../.github/prompts/archive/implement-localization.prompt.md) |
| Isolated Tool execution | Choose after per-call approval; this is an architectural security boundary, not a UI-only feature. | [Implement isolated Tool execution](../.github/prompts/implement-isolated-tool-execution.prompt.md) |
| Parallel Agents | Later bet; requires approval and isolation plus separate child state and reviewable file integration. | [Implement parallel Agents](../.github/prompts/implement-parallel-agents.prompt.md) |
| Playwright browser automation | **Shipped 2026-09-05.** Contained browser behind its own Permission, one workflow, per-Project write capabilities each approved per action. | [Archived brief](../.github/prompts/archive/implement-browser-automation.prompt.md), decision 0003 |
| Microsoft 365 work integration | Begin read-only with delegated identity, least privilege, provenance, and no send/share actions. | [Implement Microsoft 365 work integration](../.github/prompts/implement-microsoft-365-integration.prompt.md) |
| Condition-triggered automation | **Shipped**, locked to `safe` mode. | [Archived](../.github/prompts/archive/implement-event-triggered-automation.prompt.md) |

Selecting a Prompt File starts implementation discovery; it does not waive its
prerequisite or decision gates.

## DeskPilot baseline

The baseline below distinguishes shipped behavior from roadmap intent. The
sources of truth are the [requirements](010-requirements.md),
[security model](050-security-model.md), [roadmap](060-roadmap.md), and the
repository implementation and tests.

| Capability | DeskPilot status | Evidence and boundary |
| --- | --- | --- |
| Copilot agent, streaming, Vision, Attachments | Shipped | Engine-backed Turns, live Activity, image input, and bounded uploads. |
| Category Permissions | Shipped | Visible before a Turn; not a per-call approval gate. |
| Changes, Keep, Undo, Save, Checkpoints | Shipped | Pending change set, diff review, per-file Undo, Git Save, and pre-Turn Checkpoint restore. |
| Projects and non-expert Git workflows | Shipped | File explorer, Branch and Merge Wizards, Clone design, and plain-language sync. |
| Memory and context management | Shipped | User Profile, Agent Memory, session search, Compact, and Auto-compaction. |
| Customizations and MCP | Shipped | Agents, Skills, Instructions, Prompt Files, and durable MCP server configuration. |
| Intercom | Shipped | Telegram Channel with Project authorization and explicit shared-group controls. |
| Per-call approval | Shipped (Terminal) | Confirm-before-run gate on Terminal commands, risk-tiered against a safe-list. File writes and MCP calls are not yet gated. |
| Scheduled and triggered work | Shipped | Time-based schedules plus file-arrival triggers, both on the single-active-Turn dispatcher; triggers locked to `safe` mode. |
| Packaging and localization | Shipped | CurrentUser Windows package; English source locale with German shipped. |
| OS-level isolation or remote execution | Absent by design today | The security model explicitly does not claim a sandbox. |
| Parallel Agents | Absent | One Engine Runspace and one active Turn. |
| Browser/computer automation | Partial | Browsing and `fetch_url` read page content; `browser_page` drives a live page behind its own Permission, with form fill, submit, upload and download available per Project and approved per action. Desktop control is absent. |
| Multi-provider/local Models | Deliberate non-goal | DeskPilot delegates Model access and entitlement to GitHub Copilot. |

## Where DeskPilot's strength lies

### Knowledge-worker change review

DeskPilot combines a pending change set, changed-file review, Keep, Undo, Save,
and Checkpoints with a Branch and Merge Wizard. The workflow is explained and
constrained for a user who does not already understand a repository, rather
than assuming one who does.

### Copilot-native onboarding

Provider selection, API keys, endpoint compatibility, and Model pricing are
kept out of the product. DeskPilot uses the user's Copilot entitlement through
the Engine, which is a deliberate trade of breadth for a smaller setup surface,
not a missing provider picker.

### Visible work and honest Usage

Live Activity, Task List, changed-file review, priced/unpriced Usage, Context
Window visibility, and persistent Conversation history form a coherent trust
surface. Preserve this when adding automation: unattended work must produce at
least the same evidence as an interactive Turn.

### Build-free, local-first operation

The static SPA and PowerShell Host Server keep the runtime small and
inspectable. Accept a larger application shell only when it measurably improves
installation or isolation.

## Material gaps

### 1. Per-call approval

The clearest safety and product gap. Category Permissions authorize a Tool for
an entire Turn, so one allowed Terminal Tool can issue a command much broader
than the user expected.

Recommended first slice:

- Ask before each Terminal command.
- Ask before a write outside the selected Project.
- Ask before a mutating MCP call, using MCP annotations when available and a
   conservative default when they are missing.
- Route approval through the same pending-request path as Ask-User so Stop and
   Intercom remain responsive.
- Do not begin with a permanent wildcard policy editor.

> **Shipped for Terminal on 2026-09-03.** See decision 0008. The delivered
> design differs from this brief in two ways, both deliberate: the gate is
> risk-tiered against a safe-list rather than firing on every command, and
> there is **no** "allow for this Turn" option, because a class-wide grant
> silently authorises every later command of that class.

### 2. Diagnostics and support bundle

DeskPilot has health and update surfaces plus optional Turn transcripts, but no
single place that answers why the Host Server, Engine, MCP server, or Channel
is failing.

Recommended first slice:

- Read-only status for versions, paths, active Project, Engine, MCP servers,
   Intercom, and update state.
- A bounded in-memory log with live viewing and explicit retention.
- A redacted support bundle containing configuration shape, not secret values.
- A deterministic self-check command that can run without a Model Turn.

### 3. Scheduled work

Recurring report preparation, folder review, and status summaries map directly
to DeskPilot's audience.

Specify before implementation:

- What happens when a schedule fires during an active Turn.
- Whether missed work queues, coalesces, or expires.
- Which Project, Agent, Model, and Permissions snapshot a job uses.
- Which actions require fresh approval and which may run unattended.
- Where results appear and how Intercom announces them.

Start with local time-based schedules. Webhooks and external events introduce
an inbound trust boundary and should be a separate decision.

### 4. Packaging and localization

DeskPilot's launch path still exposes PowerShell and browser concepts to the
user. For the stated audience, installer quality is a feature rather than
release engineering.

Recommended order:

1. Portable, verifiable Windows package with clean install/update/uninstall.
2. Desktop shell that preserves loopback-only Host Server behavior.
3. Extract UI strings and ship German as the second language.
4. Add more languages only with a maintenance and review path.

### 5. Optional isolated execution

DeskPilot explicitly runs Tools with the user's privileges. Approval reduces
accidental damage but does not contain a malicious dependency, MCP server, or
command.

Do not replace the Engine. Add an optional execution boundary beneath the
Terminal Tool first, with explicit file mounts, environment-variable passing,
network policy, and a visible "local versus isolated" status. This is an
architectural feature and should follow, not block, per-call approval.

## Later bets

### Parallel Agents

Wait until each child can receive an isolated Project state, a bounded
Permission set, separate Usage, and a reviewable merge result. Adding
concurrency to the current shared Engine Runspace would weaken the product's
strongest trust guarantees.

### Playwright browser automation and computer control

Shipped as a contained slice (decision 0003). DeskPilot drives a throwaway
Chromium profile through a supervised Node process behind its own
`browserAutomation` Permission, off by default. **Reading** - `open`,
`click_link`, `read_page`, `screenshot` - is always available and has no external
effect. **Writing** - `fill_form`, `click_button`, `upload_file`,
`download_file` - exists only where a Project grants the matching capability, and
every write is approved individually with its values shown. Egress is bounded by
a scope derived from the address the task names; leaving it raises an approval
card showing the whole URL. General desktop control remains a separate later
decision and is explicitly out of scope.

### Microsoft 365 work integration

Joining local work to Outlook, calendar, Teams, To Do, OneDrive and SharePoint
fits DeskPilot's knowledge-worker audience, but it creates a private-data
boundary and an outbound-action surface. Start with one read-only briefing
workflow, delegated least-privilege access, visible provenance, explicit
account state, and complete disconnect/revocation. Sending, posting, sharing,
calendar changes, and background access require per-call approval and separate
decisions.

### Condition-triggered automation

DeskPilot's scheduled-work brief deliberately starts with local time-based
schedules and excludes events. After safe scheduled dispatch exists, consider
one confined local Project file event with debounce, stable-write detection,
deduplication, bounded backlog, and untrusted-event handling. Webhooks, mailbox
polling, and cloud events remain separate inbound trust decisions.

## Deliberate non-goals

- **Provider marketplace.** Multi-provider support would duplicate the Engine,
   introduce secret storage and pricing complexity, and weaken DeskPilot's
   Copilot-native positioning.
- **Messaging breadth for its own sake.** Intercom should add a Channel only
   when users need it, not to raise a gateway count.
- **A 3D office or decorative Agent theater.** It does not improve the core
   knowledge-worker workflow.
- **Autonomous self-modification.** Agent-created Skills can be useful, but
   DeskPilot should keep Customization changes explicit and reviewable.
- **RL trajectory and training infrastructure.** Valuable to model builders,
   outside DeskPilot's product scope.

## Decision gate

This record does not add requirements by itself. Before a feature moves into
the roadmap, write an Acceptance criterion and answer its safety boundary,
single-active-Turn behavior, Intercom behavior, persistence model, and rollback
path.
