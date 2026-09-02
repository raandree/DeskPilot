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
| Browser automation | Later bet; requires one named workflow, approval, isolation, and a broken lethal-trifecta path. | [Implement browser automation](../.github/prompts/implement-browser-automation.prompt.md) |

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
| Browser/computer automation | Partial | Browsing and URL fetch exist; interactive page or desktop control does not. |
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

### Browser and computer automation

Hermes has interactive browser and desktop-control Tool sets, while Cline and
OpenHands expose browser workflows. This could unlock form entry and line-of-
business web work for DeskPilot's audience. It also combines untrusted web
content, local data, and outbound actions. Require a concrete user workflow,
domain isolation, and per-action approval before adding it.

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

## Decision gate

This research does not add requirements by itself. Before a feature moves into
the roadmap, write an Acceptance criterion and answer its safety boundary,
single-active-Turn behavior, Intercom behavior, persistence model, and rollback
path. The recommended first decision is the per-call approval contract.
