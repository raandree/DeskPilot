# Spec 100 — Competitive landscape and feature decisions

> Status: research note, 2026-09-02. Claims were checked against each
> project's own repository or documentation on that date. Product claims are
> not independent security or quality assessments. "Not evidenced" means the
> reviewed sources did not establish a capability; it does not prove absence.

## Decision summary

DeskPilot should not try to match the total feature count of general-purpose
agent harnesses. Its defensible position is narrower: a Copilot-native agent
for knowledge workers, with visible safety, strong change review, and
plain-language Git workflows.

The next features with the strongest evidence are:

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

Microsoft Scout reinforces this order rather than replacing it. Its most useful
additional candidates are a read-only Microsoft 365 connection and local
condition-triggered automation. Both should follow approval; neither requires
DeskPilot to copy Scout's enterprise deployment model.

Parallel Agents and browser/computer automation are later bets. Both increase
the value of DeskPilot, but also multiply the consequences of its current
full-user-privilege execution model.

## Feature prompt chooser

Each candidate has an independent Prompt File under `.github/prompts`. Packaging
and localization are separate choices because they have different dependencies,
acceptance criteria, and rollback paths.

| Candidate | Selection guidance | Prompt File |
| --- | --- | --- |
| Per-call approval | Start here; it closes the clearest safety gap and is a prerequisite for higher-agency work. | [Implement per-call approval](../.github/prompts/implement-per-call-approval.prompt.md) |
| Diagnostics and support bundle | Choose for faster support and trustworthy failure evidence without Model Usage. | [Implement diagnostics and support bundle](../.github/prompts/implement-diagnostics-support-bundle.prompt.md) |
| Scheduled work | Choose for recurring local knowledge work after collision and unattended-Permission policy is approved. | [Implement scheduled work](../.github/prompts/implement-scheduled-work.prompt.md) |
| Windows packaging | Choose to remove PowerShell and browser-launch concepts from installation and startup. | [Implement Windows packaging](../.github/prompts/implement-windows-packaging.prompt.md) |
| Localization | Choose to ship maintainable English and German UI and safety text without a frontend build step. | [Implement localization](../.github/prompts/implement-localization.prompt.md) |
| Isolated Tool execution | Choose after per-call approval; this is an architectural security boundary, not a UI-only feature. | [Implement isolated Tool execution](../.github/prompts/implement-isolated-tool-execution.prompt.md) |
| Parallel Agents | Later bet; requires approval and isolation plus separate child state and reviewable file integration. | [Implement parallel Agents](../.github/prompts/implement-parallel-agents.prompt.md) |
| Playwright browser automation | Later bet; DeskPilot currently fetches URLs but cannot control a page. Requires one named workflow, approval, isolation, and a broken lethal-trifecta path. | [Implement Playwright browser automation](../.github/prompts/implement-browser-automation.prompt.md) |
| Microsoft 365 work integration | New Scout-derived candidate; begin read-only with delegated identity, least privilege, provenance, and no send/share actions. | [Implement Microsoft 365 work integration](../.github/prompts/implement-microsoft-365-integration.prompt.md) |
| Condition-triggered automation | New Scout-derived candidate after approval and scheduled work; begin with one confined local file event, not a webhook. | [Implement condition-triggered automation](../.github/prompts/implement-event-triggered-automation.prompt.md) |

Selecting a Prompt File starts implementation discovery; it does not waive its
prerequisite or decision gates.

## Comparison method

The peer set is relevance-based rather than a raw popularity ranking. It spans
general-purpose local agents, desktop control centers, IDE harnesses, and
terminal coding agents:

- **Hermes Agent** and **Hermes One** show the broadest personal-agent and
   desktop-control surfaces. They are one stack, not two independent runtimes.
- **OpenHands Agent Canvas** shows remote execution and automation at team
   scale.
- **Cline**, **Roo Code**, and **Continue** show mature approval and
   customization patterns in an IDE-oriented workflow.
- **Goose** and **OpenCode** show portable, multi-provider local harnesses.
- **Aider** is a useful reference for focused Git-native editing rather than
   broad orchestration.
- **Microsoft Scout** shows an enterprise-governed desktop Autopilot spanning
   local files, shell, browser, Microsoft 365, and unattended work. It is a
   preview product, not a public harness repository, so Microsoft Learn and
   Microsoft engineering publications are the primary evidence.

Continue is included as an influential reference, but its repository states
that it is read-only and no longer actively maintained.

The comparison uses two axes. **Runtime breadth** asks what the agent can do.
**Product fit** asks whether that capability helps DeskPilot's target user
without breaking its local-first, Copilot-native, single-user design.

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
| Per-call approval | Planned | Phase 1 confirm-before-run gate; not implemented. |
| OS-level isolation or remote execution | Absent by design today | The security model explicitly does not claim a sandbox. |
| Scheduled work | Deferred | Requires an idle scheduler and a policy for collisions with an active Turn. |
| Parallel Agents | Absent | One Engine Runspace and one active Turn. |
| Browser/computer automation | Partial | Browsing and `fetch_url` can read page content; Playwright, interactive page control, and desktop control are absent. |
| Multi-provider/local Models | Deliberate non-goal | DeskPilot delegates Model access and entitlement to GitHub Copilot. |

## Market capability matrix

This matrix records the capabilities that materially affect DeskPilot's
choices. `Yes` is evidenced in the cited primary sources; `Partial` means a
narrower or differently scoped form; `NE` means not evidenced in the reviewed
sources.

| Harness | Main surface | Approval policy | Isolation or remote execution | Scheduling | Agents | Extensibility | Model strategy |
| --- | --- | --- | --- | --- | --- | --- | --- |
| DeskPilot | Local web UI | Category only | No | No | One | MCP + Customizations | Copilot-native |
| Hermes Agent | TUI, API, Channels, ACP | Command approval | Docker, SSH, HPC and cloud backends | Yes | Parallel delegates | MCP, Skills, plugins, hooks | Multi-provider/local endpoint |
| Hermes One | Desktop GUI over Hermes Agent | Inherited Hermes command approval | Local or remote Agent; upstream Docker and SSH | Yes | Profiles and upstream delegates | MCP, Skills and toolsets | Multi-provider/local Models |
| OpenHands | Web control center | NE | Local, Docker, VM, remote and cloud | Schedule and webhook | Multiple Agent backends | Skills, automations and integrations | Multi-provider and ACP agents |
| Cline | IDE, TUI, headless CLI and SDK | Per-call or auto-approve | Local, hub and remote modes; isolated data directory | Cron and events | Subagents and Agent teams | MCP, Skills, plugins and hooks | Multi-provider/subscription |
| Roo Code | VS Code | Granular per-capability auto-approval | NE | NE | Modes and subtasks | MCP, Skills and custom Tools | Multi-provider |
| Continue | IDE and CLI | Per-tool allow, ask and exclude policies | NE | NE | NE | Configuration and permission policies | Multi-provider/local Models |
| Goose | Desktop, CLI and API | NE | Primarily local; remote isolation not evidenced | NE | NE | 70+ MCP extensions and ACP | 15+ providers/local Models |
| OpenCode | TUI, desktop, web and IDE | Per-agent permissions | Server/API surface; sandbox not evidenced | NE | Build, Plan and general subagent | MCP, Skills, plugins and custom Tools | Multi-provider/local Models |
| Aider | Terminal and browser UI | Interactive pair workflow | Docker option | NE | NE | Conventions and scripting | Multi-provider/local Models |
| Microsoft Scout | Windows/macOS desktop | Per-action, three-tier shell, sensitive paths | Zero-trust container/runtime mediation | Heartbeat, schedules and conditions | Parallel specialized sub-agents | MCP, Skills and Microsoft 365 | GitHub Copilot catalog |

## Microsoft Scout detailed comparison

Microsoft's preview documentation describes Scout as a desktop AI application
for Windows 11 and macOS 12 or later. It reads and writes files, runs shell
commands, controls a browser, connects to Microsoft 365, and works in the
background. The evidence below separates documented capability from product
positioning and from the user-supplied hands-on transcript.

| Capability | Scout evidence | DeskPilot implication |
| --- | --- | --- |
| Files, shell, code and web research | Microsoft Learn documents workspace and approved external-folder access, shell commands, code changes, builds, tests, and cited web research. | DeskPilot has the core local Tool surface; preserve its stronger non-expert change review. |
| Per-action approval | Microsoft Learn documents auto-approve, prompt and deny tiers, exact command/content previews, sensitive paths, and admin-enforced prompts for non-read actions. | Strengthens per-call approval as the first candidate. Category Permissions alone are not equivalent. |
| Browser automation | Microsoft Learn documents navigation, clicks, form entry, uploads, screenshots, page snapshots, console logs, and network inspection; the admin policy can block browser origins. | Strengthens the Playwright candidate and its separate Permission, egress policy, and hostile-site tests. |
| Autonomous work | Heartbeat repeats one prompt every 15–120 minutes in work hours. Automations run on schedules or conditions, support one-shot runs, and retain history. Background modes use stricter Permissions and skip actions that need approval. | Scheduled work remains one candidate. Condition-triggered automation is a separate later candidate because it adds an event trust boundary. |
| Parallel delegation | Scout launches Explore, Task, Code review, Research, and General-purpose sub-agents in isolated contexts and can run them in parallel. | Strengthens the existing parallel-Agents brief, but does not remove its isolation and file-integration prerequisites. |
| Microsoft 365 and Work IQ | Microsoft Learn documents Outlook, calendar, Teams, To Do, meeting transcripts and rooms, SharePoint Lists, inbox rules, OneDrive/SharePoint files and sharing, plus cross-service Work IQ queries. Mutating shared actions require approval. | Adds a read-only Microsoft 365 candidate. DeskPilot should not call a Graph-only connection Work IQ or begin with outbound mutations. |
| Memory and history | Scout proactively stores provenance-bearing memories, searches past sessions, supports restore, and stores session/memory data in OneDrive. | DeskPilot already has Agent Memory, session search, Compact, Auto-compaction, Checkpoints, and local Conversation history. Scout's provenance and aging model are useful refinements, not a new top-level gap. |
| Skills, MCP and documents | Scout discovers `SKILL.md`, ships Office/Loop/web-artifact Skills, supports MCP, and offers concurrent Co-Create editors. | DeskPilot already has Skills, MCP, Attachments, Artifacts, and file review. Bundled document Skills and live co-editing are possible later UX investments, below the safety gaps. |
| Models and context | Scout inherits the GitHub Copilot Model catalog and exposes per-message Model choice, reasoning effort, context size, and conversation compaction. | Broad parity is already strong; DeskPilot remains intentionally Copilot-native. |
| Enterprise governance | Frontier enrollment, Intune policy, organization attestation, Microsoft 365 and GitHub Copilot licensing, model/provider blocks, disabled Tool servers, workspace confinement, and browser-egress blocks are documented. | Relevant for managed deployment, but not an immediate requirement for DeskPilot's current local, single-user scope. Adopt the policy ideas at user level before enterprise administration. |
| Runtime security | Microsoft states the agent container is untrusted and every Tool call, Model request, and network hop is mediated by a zero-trust runtime with identity, tokens, and policy outside the container. External content is tagged as untrusted; Microsoft also warns that GitHub Copilot processing can fall outside Microsoft 365 protections. | Strengthens optional isolated Tool execution and explicit data-flow disclosure. Content tagging is defense in depth, not a substitute for breaking unsafe data paths. |
| Availability | Scout is an experimental Frontier preview. Sign-in requires organization enrollment, Intune enablement and attestation, Microsoft 365 access, and GitHub Copilot Business or Enterprise. | Do not benchmark onboarding or maturity as if Scout were generally available. |

The supplied Shane Young transcript demonstrates the preview UI for approvals,
Playwright, package installation, generated scripts, Skills, MCP, automations,
heartbeat, Memory, Model selection, and Work IQ. Those observations agree with
Microsoft Learn, but the transcript remains secondary evidence and is not used
to establish capabilities that the fetched Microsoft sources do not document.

## Where DeskPilot is ahead

### Knowledge-worker change review

DeskPilot combines a pending change set, changed-file review, Keep, Undo, Save,
and Checkpoints with a Branch and Merge Wizard. Coding harnesses expose diffs
and checkpoints, but their primary interaction assumes a developer already
understands a repository. DeskPilot explains and constrains the workflow for a
user who does not.

### Copilot-native onboarding

Most peers make provider selection, API keys, endpoint compatibility, and
Model pricing part of the product. DeskPilot turns that breadth into a smaller
setup surface by using the user's Copilot entitlement through the Engine. That
is a strategic trade, not a missing provider picker.

### Visible work and honest Usage

Live Activity, Task List, changed-file review, priced/unpriced Usage, Context
Window visibility, and persistent Conversation history form a coherent trust
surface. Preserve this advantage when adding automation: unattended work must
produce at least the same evidence as an interactive Turn.

### Build-free, local-first operation

The static SPA and PowerShell Host Server keep the runtime small and inspectable.
Hermes One, OpenHands, Cline, Goose, and OpenCode gain broader distribution or
runtime options through larger application stacks. DeskPilot should accept a
larger shell only when it measurably improves installation or isolation.

## Material gaps

### 1. Per-call approval

This is the clearest safety and product gap. Cline asks before file edits and
Terminal commands, Roo separates auto-approval by capability, and Continue
persists allow/ask/exclude policies. DeskPilot currently authorizes a category for
the entire Turn. One allowed Terminal Tool can therefore issue a command much
broader than the user expected.

Recommended first slice:

- Ask before each Terminal command.
- Ask before a write outside the selected Project.
- Ask before a mutating MCP call, using MCP annotations when available and a
   conservative default when they are missing.
- Offer **allow once**, **allow for this Turn**, and **deny**. Do not begin with
   a permanent wildcard policy editor.
- Route approval through the same pending-request path as Ask-User so Stop and
   Intercom remain responsive.

### 2. Diagnostics and support bundle

Hermes exposes a `doctor` command; Hermes One adds an in-app log viewer,
debug dump, and backup/import; Cline exposes `doctor`, repair, and logs; Goose
links diagnostics as a first-class support path. DeskPilot has health and
update surfaces plus optional Turn transcripts, but no single place that
answers why the Host Server, Engine, MCP server, or Channel is failing.

Recommended first slice:

- Read-only status for versions, paths, active Project, Engine, MCP servers,
   Intercom, and update state.
- A bounded in-memory log with live viewing and explicit retention.
- A redacted support bundle containing configuration shape, not secret values.
- A deterministic self-check command that can run without a Model Turn.

### 3. Scheduled work

Hermes, Hermes One, OpenHands, and Cline all support scheduled agent work;
OpenHands and Cline also support event-triggered runs. This is unusually
relevant to knowledge workers: recurring report preparation, folder review,
and status summaries map directly to DeskPilot's audience.

Specify before implementation:

- What happens when a schedule fires during an active Turn.
- Whether missed work queues, coalesces, or expires.
- Which Project, Agent, Model, and Permissions snapshot a job uses.
- Which actions require fresh approval and which may run unattended.
- Where results appear and how Intercom announces them.

Start with local time-based schedules. Webhooks and external events introduce
an inbound trust boundary and should be a separate decision.

### 4. Packaging and localization

Hermes One, Goose, OpenCode, and Roo Code provide native or packaged clients;
Hermes One and OpenCode also expose localization infrastructure. DeskPilot's
launch path still exposes PowerShell and browser concepts to the user. For the
stated audience, installer quality is a feature rather than release
engineering.

Recommended order:

1. Portable, verifiable Windows package with clean install/update/uninstall.
2. Desktop shell that preserves loopback-only Host Server behavior.
3. Extract UI strings and ship German as the second language.
4. Add more languages only with a maintenance and review path.

### 5. Optional isolated execution

Hermes offers Docker, SSH, HPC, and cloud Terminal backends; OpenHands treats
Docker, VM, remote, and cloud backends as a core boundary. DeskPilot explicitly
runs Tools with the user's privileges. Approval reduces accidental damage but
does not contain a malicious dependency, MCP server, or command.

Do not replace the Engine. Add an optional execution boundary beneath the
Terminal Tool first, with explicit file mounts, environment-variable passing,
network policy, and a visible "local versus isolated" status. This is an
architectural feature and should follow, not block, per-call approval.

## Later bets

### Parallel Agents

Hermes, OpenHands, Cline, and OpenCode establish that delegation is becoming a
normal harness capability. DeskPilot should wait until each child can receive
an isolated Project state, a bounded Permission set, separate Usage, and a
reviewable merge result. Adding concurrency to the current shared Engine
Runspace would weaken the product's strongest trust guarantees.

### Playwright browser automation and computer control

Hermes has interactive browser and desktop-control Tool sets, while Cline and
OpenHands expose browser workflows. This could unlock form entry and line-of-
business web work for DeskPilot's audience. It also combines untrusted web
content, local data, and outbound actions. DeskPilot currently has only URL
fetching through the Engine's Browsing Tool and has no Playwright dependency.
Use Playwright for the first browser-only slice, but require a concrete user
workflow, domain isolation, and per-action approval before adding it. Treat
general desktop control as a separate later decision.

### Microsoft 365 work integration

Scout's most product-specific advantage is joining local work to Outlook,
calendar, Teams, To Do, OneDrive, SharePoint, and cross-service Work IQ queries.
This fits DeskPilot's knowledge-worker audience, but it creates a private-data
boundary and an outbound-action surface. Start with one read-only briefing
workflow, delegated least-privilege access, visible provenance, explicit account
state, and complete disconnect/revocation. Sending, posting, sharing, calendar
changes, and background access require per-call approval and separate decisions.

### Condition-triggered automation

Scout distinguishes periodic heartbeat from discrete schedule- or
condition-triggered automations. DeskPilot's scheduled-work brief deliberately
starts with local time-based schedules and excludes events. Keep that boundary.
After safe scheduled dispatch exists, consider one confined local Project file
event with debounce, stable-write detection, deduplication, bounded backlog, and
untrusted-event handling. Webhooks, mailbox polling, and cloud events remain
separate inbound trust decisions.

## Deliberate non-goals

- **Provider marketplace.** Multi-provider support is table stakes for general
   harnesses, but it would duplicate the Engine, introduce secret storage and
   pricing complexity, and weaken DeskPilot's Copilot-native positioning.
- **Messaging breadth for its own sake.** Intercom should add a Channel only
   when users need it; matching Hermes One's gateway count is not a product goal.
- **A 3D office or decorative Agent theater.** It does not improve the core
   knowledge-worker workflow.
- **Autonomous self-modification.** Agent-created Skills can be useful, but
   DeskPilot should keep Customization changes explicit and reviewable.
- **RL trajectory and training infrastructure.** Valuable to model builders,
   outside DeskPilot's product scope.

## Primary sources

- [Hermes Agent README](https://github.com/NousResearch/hermes-agent) and
   [tools and Tool backends](https://hermes-agent.nousresearch.com/docs/user-guide/features/tools)
- [Hermes One README](https://github.com/fathah/hermes-desktop)
- [OpenHands Agent Canvas README](https://github.com/OpenHands/OpenHands) and
   [architecture](https://github.com/OpenHands/OpenHands/blob/main/docs/architecture.md)
- [Cline README](https://github.com/cline/cline) and
   [CLI README](https://github.com/cline/cline/blob/main/apps/cli/README.md)
- [Roo Code features](https://docs.roocode.com/features) and
   [auto-approval policy](https://docs.roocode.com/features/auto-approving-actions)
- [Continue repository](https://github.com/continuedev/continue) and
   [CLI Tool permissions](https://docs.continue.dev/cli/tool-permissions)
- [Goose repository](https://github.com/aaif-goose/goose)
- [OpenCode documentation](https://opencode.ai/docs/) and
   [permissions](https://opencode.ai/docs/permissions/)
- [Aider repository](https://github.com/Aider-AI/aider) and
   [documentation](https://aider.chat/docs/)
- [Microsoft Scout overview](https://learn.microsoft.com/en-us/microsoft-scout/overview),
  [user guide](https://learn.microsoft.com/en-us/microsoft-scout/use-microsoft-scout),
  [Microsoft 365 guide](https://learn.microsoft.com/en-us/microsoft-scout/work-with-microsoft-365),
  [Responsible AI FAQ](https://learn.microsoft.com/en-us/microsoft-scout/microsoft-scout-responsible-ai-faq),
  [admin controls](https://learn.microsoft.com/en-us/microsoft-scout/manage-group-policy),
  and [Microsoft engineering account](https://commandline.microsoft.com/project-lobster-openclaw-personal-ai-assistant-enterprise-secure/)

## Decision gate

This research does not add requirements by itself. Before a feature moves into
the roadmap, write an Acceptance criterion and answer its safety boundary,
single-active-Turn behavior, Intercom behavior, persistence model, and rollback
path. The recommended first decision is the per-call approval contract.
