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
- Confirm-before-run gate for Terminal and out-of-folder writes.

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

### Phase 2.7 — Memory & context (Hermes-inspired batch)

Ideas migrated after reviewing a similar local agent tool (Hermes): its
**Memory & Context** settings and **Usage** screen. Kept the parts that fit the
build-free, local-first, cost-honest constraints; dropped the rest.

- ~~**Automatic conversation compaction** (FR-C19).~~ **Done** — builds directly
  on the manual Compact + Context Window gauge (FR-C18). After a Turn, when the
  measured occupancy reaches a configurable threshold, DeskPilot summarises the
  earlier replayed history automatically (reusing `POST /compact`), announces it
  with a toast, and preserves the visible transcript. Three Settings: toggle
  (default on), threshold percent (50–95, default 80), recent-messages-to-keep
  (2–100, default 4). Mirrors Hermes's Auto-Compression / Compression Threshold /
  Protected Recent Messages.
- ~~**Usage view enhancements** (FR-U5).~~ **Done** — the Usage popover now shows
  the **tokens in / tokens out** split and a **Top models** list (session, by
  tokens), and the credits-per-day chart gained a **30-day** range. All from data
  already tracked; no Engine change. Mirrors Hermes's Tokens IN/OUT, Top Models,
  and 7/30/90-day range.

### Phase 2.8 — Persistent memory (learns who you are)

The Hermes memory idea researched after the compaction batch: an agent that
"builds a deepening model of who you are across sessions."

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

### Deliberately deferred (constraint or Engine bound)

- **System / diagnostics screen with live logs + update/restart** (Hermes's
  *System* screen). The status/version/active-session parts overlap the existing
  Settings → Engine panel and `/api/health`; the genuinely new parts — a live
  server **log stream** and in-app **update / restart** — need a logging ring
  buffer threaded through the Host Server and a self-update path, a larger,
  separate track. Spec it before building.
- **External memory providers** (Hermes's *Memory Provider* plugins — Honcho,
  Mem0, Hindsight, etc.). DeskPilot now has its own bounded, built-in persistent
  memory (Phase 2.8); pluggable external backends are a larger, later track that
  would need a provider abstraction and their own dependencies.
- **Top Skills usage panel** (Hermes's *Top Skills*). The Engine does not report
  which Skill a Turn invoked, so per-Skill activity can't be measured without a
  ShellPilot change (the "Engine is sacrosanct" pattern).
- **Knowledge base / RAG over a corpus.** Real vector RAG needs a vector DB,
  against the build-free constraint. The `#file` mention is the constraint-
  respecting middle ground for now; a pinned-reference set is a later candidate.
- **Scheduled / recurring prompts.** Powerful for ops, but needs an idle
  scheduler and conflicts with the single-active-Turn rule. Spec it before
  building.
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
