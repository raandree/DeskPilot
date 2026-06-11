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
  (`POST /api/conversations/{id}/stop` sets a cancel flag the Turn loop honors,
  stopping the Engine shell and emitting a "Turn stopped." error frame; FR-C6).
- Live Activity events during a Turn (not just at `done`).
- Ask-User Tool routed into the thread (FR-T4).
- ~~Disk persistence of Conversations (FR-C7).~~ **Done** — Conversations and a
  lifetime Usage counter now persist to a per-user data directory; the lifetime
  counter has a manual reset (FR-C7, FR-C8, FR-U3, FR-U4).
- ~~Persist Settings (model, permissions, Workspace Folder) across sessions too.~~
  **Done** (FR-S1).
- ~~File uploads (FR-C9).~~ **Done** — Upload button saves files to the Workspace
  Folder and the agent reads them through its existing File Tool.
- Confirm-before-run gate for Terminal and out-of-folder writes.

## Phase 2 — Reach & richness

- Vision (image attachments) and structured-output surfaces.
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
- ~~Drag-and-drop attachments onto the composer (FR-C14).~~ **Done.**
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

### Deliberately deferred (constraint or Engine bound)

- **Knowledge base / RAG over a corpus.** Real vector RAG needs a vector DB,
  against the build-free constraint. The `#file` mention is the constraint-
  respecting middle ground for now; a pinned-reference set is a later candidate.
- **Scheduled / recurring prompts.** Powerful for ops, but needs an idle
  scheduler and conflicts with the single-active-Turn rule. Spec it before
  building.
- **MCP server support.** The Engine owns Tool wiring; surface MCP servers only
  once ShellPilot exposes them (see the "Engine is sacrosanct" pattern).
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
