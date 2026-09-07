# 060 — Roadmap

## Phase 0 — Foundations (this bootstrap)

- Memory Bank + specs.
- Host Server skeleton: `HttpListener` router, static serving, health, settings,
  models, conversations CRUD, SSE message streaming, Engine integration.
- Static SPA: sidebar, thread, composer, model picker, Permissions, Activity,
  Usage, auth screen.
- Launcher + session token.
- Pester tests for Host Server helpers; README + CHANGELOG.

**Exit:** a user can authenticate, chat with streaming, run a File/Browsing Tool
task, see Activity and Usage — all from the window.

## Phase 1 — Robustness & trust

- ~~Stop-a-Turn end to end.~~ **Done** — a Stop button cancels the running Turn
  immediately in the UI, then the Host Server stops the Engine pipeline
  asynchronously and persists a stopped Message with partial Usage. When a hard
  stop prevents exact provider totals, the credits are labelled as an input-only
  estimate (`POST /api/conversations/{id}/stop`; FR-C6).
- ~~Live Activity events during a Turn (not just at `done`).~~ **Done** — every
  tool call is announced before it runs as an `activity` SSE frame, so the
  Activity panel lists what the agent is reading, writing, running, fetching and
  searching as it happens, and keeps that ordered account on the Message.
- ~~Ask-User Tool routed into the thread (FR-T4).~~ **Done** — a structured
  Engine Tool event opens an in-thread answer card; the correlated response
  resumes the same Turn without an interactive console.
- ~~Disk persistence of Conversations (FR-C7).~~ **Done** — Conversations and a
  lifetime Usage counter now persist to a per-user data directory; the lifetime
  counter has a manual reset (FR-C7, FR-C8, FR-U3, FR-U4).
- ~~Persist Settings (model, permissions, Workspace Folder) across sessions too.~~
  **Done** (FR-S1).
- ~~File uploads (FR-C9).~~ **Done** — Upload button saves files to the Workspace
  Folder and the agent reads them through its existing File Tool; drag-and-drop
  and clipboard paste use the same Attachment flow.
- ~~Per-call approval for Terminal commands.~~ **Done** (FR-PA1–FR-PA12).
  DeskPilot passes `-DisableTerminal` and registers its own
  `run_terminal_command`, which blocks before the side effect. A shipped
  safe-list of read-only commands runs without asking; everything else prompts,
  unless the operator explicitly selects **Allow for this Turn** for the same
  Terminal scope. Once-only remains the default; Stop and scope revocation
  invalidate the grant. Requires an Engine that refuses to dispatch a
  disabled built-in; DeskPilot probes for that and fails loudly without it.
- **Blocked — per-call approval for the remaining risky actions.** Outside-Project
  writes and mutating MCP calls still need approval while category Permissions
  remain in force. DeskPilot must not simulate approval from an Activity event
  after dispatch. Work resumes only after ShellPilot satisfies
  [the pre-dispatch Engine contract](120-per-call-approval-engine-contract.md).

## Phase 2 — Reach & richness

- ~~Vision for image Attachments.~~ **Done** — uploaded images are passed to the
  Engine's native `-Image` input for Vision-capable Models.
- Structured-output surfaces.
- User Tool management UI (`Register-ShpTool`).
- Skill/Instruction browser (discover, preview, enable).
- ~~Per-Conversation system prompt / agent file.~~ **Partly done** — an **Agent**
  picker selects an `*.agent.md` persona whose body becomes the Turn system
  prompt (currently a global Setting, not yet per-Conversation; FR-M5).
- Cumulative cost budgets and warnings.

## Phase 2.5 — Knowledge-worker quality of life

A batch of approachability and trust features that fit the build-free,
local-first, single-user constraints (most need no new dependency):

- ~~Conversation search across titles and Message text (FR-C10).~~ **Done.**
- ~~Pin / archive Conversations (FR-C11).~~ **Done.**
- ~~Export a Conversation as a Markdown transcript (FR-C12).~~ **Done.**
- ~~Voice: dictation + read-aloud via the browser speech APIs (FR-C13).~~ **Done.**
- ~~Drag-and-drop and clipboard-paste Attachments in the composer (FR-C14).~~
  **Done.** Text-only paste remains normal text input.
- ~~Durable user **Preferences** injected into the system prompt (FR-M7).~~ **Done.**
- ~~Prompt File `/` menu and `#file` mention in the composer (FR-M8).~~ **Done.**
- ~~"Explain this Customization" (FR-X6).~~ **Done.**
- ~~Git: undo a Turn's file changes + inline diff (FR-T6, FR-T7).~~ **Done.**
- ~~Atelier health panel (FR-S4).~~ **Done.**
- ~~Artifact preview for `html` / `svg` blocks in a sandboxed frame (FR-G1).~~ **Done.**

### Phase 2.6 — Re-run, navigate, focus (second QoL batch)

- ~~Regenerate the last assistant response (FR-C15).~~ **Done.**
- ~~Edit a previous user message and resend, truncating what followed (FR-C16).~~ **Done.**
- ~~Reference files injected into every Turn (build-free light retrieval; FR-M9).~~ **Done.**
- ~~Command palette (Ctrl/Cmd+K) + global keyboard shortcuts (FR-M10).~~ **Done.**
- ~~Per-session spend warning (FR-M11).~~ **Done.**

### Phase 2.7 — Memory & context

A batch aimed at one problem: a long Conversation silently gets more expensive
and less accurate as replayed history grows. Each item here is kept only where
it fits the build-free, local-first, cost-honest constraints.

- ~~**Automatic conversation compaction** (FR-C19).~~ **Done** — builds directly
  on the manual Compact + Context Window gauge (FR-C18). After a Turn, when the
  measured occupancy reaches a configurable threshold, DeskPilot summarises the
  earlier replayed history automatically (reusing `POST /compact`), announces it
  with a toast, and preserves the visible transcript. Three Settings: toggle
  (default on), threshold percent (50–95, default 80), recent-messages-to-keep
  (2–100, default 4).
- ~~**Usage view enhancements** (FR-U5).~~ **Done** — the Usage popover now shows
  the **tokens in / tokens out** split and a **Top models** list (session, by
  tokens), and the credits-per-day chart gained a **30-day** range. All from data
  already tracked; no Engine change.

### Phase 2.8 — Persistent memory (learns who you are)

Researched after the compaction batch: an agent that builds a deepening model of
who the user is across sessions, rather than starting cold every Conversation.

- ~~**User Profile + Agent Memory** (FR-M12).~~ **Done** — two bounded stores
  injected into every Turn's system prompt: the **User Profile** (the manual
  preferences block, 8,000 chars) and a new agent-curated **Agent Memory**
  (12,000 chars, `agent-memory.json`), fenced as reference-not-instructions. Sized
  a few times larger than the minimalist ~3,600-char reference design while still a
  small fraction of a modern context window.
- ~~**Autonomous + manual learning** (FR-M13).~~ **Done** — a throttled,
  best-effort post-Turn pure-reasoning pass (`POST /api/memory/learn`, default on,
  toasted, toggleable) folds durable declarative facts into the Agent Memory,
  excluding secrets and transient state; a manual "update from this conversation"
  action plus a full view/edit/clear surface in Settings back it up. Reuses the
  auto-title / compaction pattern; no Engine change.

### Phase 2.9 — Diagnostics and support bundle

- ~~**Diagnostics, live Host Server log, and redacted support bundle.**~~
  **Done** — a calm Diagnostics modal reports DeskPilot, PowerShell, Engine, Git,
  operating-system, path, Project, authentication, MCP, Intercom, and Update
  state. A deterministic background self-check uses only bounded local read
  probes and consumes no Copilot credits. A synchronized 500-entry / 1 MiB log
  ring is polled only while the modal is open and clears on request or restart.
  An explicit action creates one allow-listed, path-minimized support ZIP under
  the data directory, capped at 2 MiB input / 3 MiB archive and protected from
  traversal, reparse redirection, overwrite, and concurrent export.

### Phase 2.10 — Contained browser automation

- ~~**A browser DeskPilot drives, not the user's own.**~~ **Done** — a supervised
  Playwright child process with a throwaway profile (no sign-ins, no history, no
  extensions, no local file access), behind its own `browserAutomation`
  Permission that ships off. Reading (`open`, `click_link`, `read_page`,
  `screenshot`) is always available; writing (`fill_form`, `click_button`,
  `upload_file`, `download_file`) exists only where a Project grants the matching
  capability, and every write is approved individually with its values shown.

  Egress is bounded by a scope derived from the address the task names. Policy is
  enforced twice because neither point sees what the other does — in PowerShell
  before a navigation so the card can be raised first, and in the supervisor's
  request interceptor where redirects, frames, pop-ups and sub-resources are
  visible — and both are held to one shared conformance corpus.

  Playwright is pinned and installs only from an explicit Diagnostics action;
  Diagnostics also reports leftover browsers and offers cleanup and uninstall.
  Proved by a hostile-site suite (24 cases) that attacks the boundary from a real
  page, and by the authorised workflow running end to end against the live site.

- **Still open.** General desktop, keyboard, mouse and screen control remains a
  separate later decision and is explicitly out of scope. `click_link` follows
  in-scope links without a card, which is a residual gap on a site with
  destructive GET links.

### Optional isolated Terminal

The opt-in Local/Isolated implementation uses disposable Docker Desktop/WSL2
containers, read-only Project access by default, network-off or exact HTTPS
allow-lists, environment grants, resource bounds, and non-routine approvals.
Diagnostics prepares, checks and removes the runtime. Read-write paths feed
pending changes and Undo; no other Tool is isolated.

Release requires the clean-environment boundary suite, full Sampler gate,
independent security review, and an obtainable dispatch-enforcing Engine. The
development Engine 0.4.1 is staged locally, not yet published.
The final local gate passed 2286 tests, with zero failures and five unchanged
browser skips; 29 real-container isolation cases ran. The independent review's
Major protocol finding was fixed. Live Copilot acceptance awaits reauthentication;
deterministic HTTP acceptance and Undo passed with an explicitly scripted provider.
See [setup, limitations and rollback](../docs/isolated-terminal.md).

### Deliberately deferred (constraint or Engine bound)

- **Single-child Agent isolation prerequisite: approved but incomplete.**
  V2's private Tool storage/lifecycle and Host Server refusal surface are
  implemented and tested. Complete Engine request admission, the credentialless
  child Engine process, child approvals, aggregate limits, authenticated live
  proof, and clean-install support remain open. Independent review returned
  request changes; no child startup or parallel scheduling is enabled. See
  [component evidence and open gates](../docs/child-agent-isolation.md).

- **External memory providers** (pluggable third-party memory backends such as
  Honcho or Mem0). DeskPilot now has its own bounded, built-in persistent
  memory (Phase 2.8); pluggable external backends are a larger, later track that
  would need a provider abstraction and their own dependencies.
- **Top Skills usage panel.** The Engine does not report
  which Skill a Turn invoked, so per-Skill activity can't be measured without a
  ShellPilot change (the "Engine is sacrosanct" pattern).
- **Knowledge base / RAG over a corpus.** Real vector RAG needs a vector DB,
  against the build-free constraint. The `#file` mention is the constraint-
  respecting middle ground for now; a pinned-reference set is a later candidate.
- **Scheduled / recurring prompts.** **Shipped.** A local, time-based schedule
  produces queued work that the existing single-active-Turn dispatcher drains on
  the accept loop's idle tick, so no second scheduler or Runspace was needed.
  Collision, catch-up, expiry, restart-claim and unattended-Permission policies
  are specified in 010 (FR-SW1..SW9), 020, 030 and 050.
- **Multi-Model side-by-side compare.** Conflicts with the single-Turn runspace
  model; lower priority for this audience.
- **Mermaid / charting artifacts.** Rendering needs a JS library or a CDN,
  which breaks build-free + offline. Revisit if a vendored renderer is accepted.

## Phase 3 — Packaging & polish

- WebView2 single-window desktop shell (true app feel).
- One-click installer / portable bundle for non-technical users.
- First-run wizard that also offers to clone a Skills/Instructions starter set
  (e.g. from the AgenticOperatingModel memory-bank template).
- Optional telemetry-free "usage diary" export.

## Phase 4 — Teaching mode

- Inline explanations tied to the Agentic Operating Model modules ("why Git
  matters", "what a Skill is") shown contextually.
- Guided example tasks (corpus analysis, ops runbook, correspondence draft)
  mapped to the training's demos.

## Cross-cutting, ongoing

- Track Engine (ShellPilot) changes and surface new capabilities.
- Keep the Memory Bank and specs current with each shipped change.
- Accessibility and localisation passes.
