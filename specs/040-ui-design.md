# 040 — UI Design

## Design language

Calm, legible, and distinctly its own. Generous whitespace, a single teal accent,
a humanist sans for Messages, system UI for chrome. Light and dark themes.
Nothing blinks; motion is subtle (token fade-in, panel slide). The window should
feel like a focused writing tool, not a dashboard — a deep-teal / petrol identity
that is deliberately not the warm-clay look of other assistants.

### Palette (tokens)

| Token | Light | Dark |
| --- | --- | --- |
| `--bg` | `#eef3f2` | `#0c1c1f` |
| `--surface` | `#ffffff` | `#11272b` |
| `--text` | `#0f1f1d` | `#e4efed` |
| `--muted` | `#576a67` | `#8aa4a0` |
| `--accent` | `#0d7d6e` (deep teal) | `#2dd4bf` (bright teal) |
| `--on-accent` | `#ffffff` | `#04231f` |
| `--border` | `#d6e2df` | `#21424a` |
| `--danger` | `#b42318` | `#f97066` |

A deep-teal / petrol palette: cool and crisp in light mode, dark blue-green in
dark mode, with a vivid teal accent. `--on-accent` carries text and glyphs on
accent fills so the bright dark-mode accent stays legible.

## Layout

```text
┌──────────┬─────────────────────────────────┐
│ Sidebar  │  Topbar: title · Model picker · ⚙ │
│          ├─────────────────────────────────┤
│ + New    │                              │
│          │   Message thread             │
│ Convo 1  │   (streaming)                │
│ Convo 2  │                              │
│ …        │                              │
│          ├─────────────────────────────────┤
│ Usage    │  Composer  [Permissions] [Send]│
└──────────┴─────────────────────────────────┘
```

## Screens & components

### 1. Authenticate (first run)

- Centered card: "Connect DeskPilot to GitHub Copilot."
- A big **Connect** button → starts `POST /api/auth/start` (SSE).
- Shows the **user code** in a large monospace pill with a Copy button and an
  **Open GitHub** link to the verification URL.
- A spinner + "Waiting for authorisation…"; on `done`, fades into the chat.
- On `error`, an inline message with **Try again**.

### 2. Sidebar

- **+ New** Conversation button (primary).
- Conversation list: title, relative time, hover actions (rename, delete).
- Footer: cumulative **Usage** chip (tokens · $cost) → opens a Usage popover;
  a **🧩 Customizations** button → the Customizations surface; and the
  **⚙ Settings** button.
- Collapsible on narrow widths.

### 3. Topbar

- Conversation title (inline-editable).
- **Model picker** dropdown (from `/api/models`), with context/cost hints.
- **☰ Files** toggle → opens the collapsible Project file explorer (disabled
  when no Project is selected).
- **⚙ Settings** button → Settings drawer.

### 4. Message thread

- User Messages: right-aligned, subtle surface.
- Assistant Messages: left-aligned, full width, Markdown-rendered (headings,
  lists, tables, code with copy buttons).
- **Streaming**: tokens fade in; a caret blinks at the tail until `done`.
- **Activity** block per assistant Message: a collapsible "Used N tools" strip
  listing files read/written, commands run, pages fetched, questions asked —
  each with an icon. Collapsed by default once complete.
- **Tasks** block per assistant Message: a compact panel showing the agent's
  in-Turn Task List as the agent works, with a header `Tasks — {completed}/{total}`
  and one row per Task. Each row carries a status glyph (`not-started` ○,
  `in-progress` ◐, `completed` ✓) and the Task title. The full list replaces
  the panel on every update (idempotent), so at most one Task is ever
  `in-progress`. Hidden when the list is empty or `taskTracking` is off.
  Persisted on the Message and replayed on reload.
- **Thinking** block (when reasoning present / showThinking on): collapsible,
  dim, above the answer.
- **Usage** footer per assistant Message: tokens · $cost · credits · duration.
- Hover actions: copy, regenerate.

### 5. Composer

- Auto-growing textarea; **Enter** sends, **Shift+Enter** newline.
- **Prompt history**: **↑** recalls previous prompts and **↓** moves toward the
  newest (shell-style), seeded from the Conversation and growing as you send. Up
  recalls from the first line, Down from the last, so multi-line editing is
  unaffected; the in-progress draft is restored when arrowing past the newest.
- Left of Send: a **Permissions** popover button showing five toggles
  (Browsing, File, Terminal, Ask-User, User Tools) with one-line risk notes and
  a colour cue (Terminal/File flagged as powerful).
- **Project** dropdown (the working folder for new prompts) plus a **＋ Project**
  button to register a new one; the selected Project persists as the default.
  When a Project is active the dropdown also offers **✕ Close project**, which
  deselects it (no Workspace Folder) while leaving it registered; the chip then
  reads **No project**. Registering opens a **folder picker** modal (drive
  switcher, breadcrumb path, Up/Home, a scrollable sub-folder list, and New
  folder) so the user browses to a folder instead of typing an absolute path.
- **Attach** button to upload files (into the selected Project, or a
  data-directory uploads folder when no Project is active).
- **Send** turns into **Stop** while a Turn streams.
- **Mid-Turn dispatch.** When a Turn is streaming and the user starts typing,
  a chevron (`▾`) appears next to **Stop** and opens a small popover with three
  options:
  - **→ Stop and Send** — cancels the running Turn and immediately sends the
    typed prompt as a new Turn.
  - **+ Add to Queue** (`Alt+Enter`) — buffers the prompt; the SPA fires it as
    a fresh Turn the moment the current one ends. Pending entries appear as
    chips above the textarea with a `×` to discard.
  - **↑ Steer with Message** (`Enter`, the default while streaming) — same as
    Queue, but the prompt sent to the Engine is wrapped with a steering
    preamble so the Model treats it as a course-correction. The user's bubble
    in the thread shows a small `Steered mid-turn` badge afterwards; queued
    messages get `Sent from queue`.

  Dispatch is purely client-side — see
  [030-api-contract.md](030-api-contract.md#mid-turn-dispatch-client-only-ux).

### 6. Settings drawer

- Default Model, default Permissions, Projects (register/select/close/remove).
  The active Project row offers **Close** (deselect, keep registered) alongside
  **Remove** (unregister).
- **Agents folder** (path to `*.agent.md` personas; the Agent itself is picked
  from the composer dropdown).
- Skill roots, Instruction roots and Prompt roots (add/remove folder paths).
- Reasoning effort (model-aware: the menu offers only the levels the effective
  Model advertises, and notes when a Model supports none), Show thinking, Max
  tool iterations.
- **Task tracking**: when on (default), the agent is given the
  `manage_todo_list` tool and the Tasks panel renders live during a Turn.
- Theme (system/light/dark).
- Engine status (path, version, auth) + a **Re-authenticate** action.
- **Back up & restore** of all settings as a JSON file.

### 6a. Project file explorer (right panel)

A collapsible right-hand panel listing the selected Project's folders and files,
with lazy-expanding directories and file sizes. Collapsed and non-expandable when
no Project is selected; refreshes after each Turn so files the agent creates
appear. A **Git bar** at the top of the panel shows whether the Project folder is
a Git repository: if not, a warning with a **git init** button; if so, the
current branch and a dropdown to switch between local branches (switching
refreshes the file tree).

### 6b. Customizations (manage AI resources)

A full-height modal opened from the sidebar's **🧩 Customizations** button. It
has two views:

- **List view.** A left rail of categories — **Agents**, **Skills**,
  **Instructions**, **Prompt files** — each with an icon and a count. The main
  pane has a **search** box and a **＋ New** button, then the selected
  category's items grouped by scope (`User` / `Workspace`), each row showing the
  name and a one-line description. Empty categories explain how to configure a
  root in Settings.
- **Editor view.** Opened by clicking an item (or after **＋ New** prompts for a
  name). A back arrow (`←`) returns to the list; the header shows the name and
  the file path. The body is a **line-numbered editor** (a monospace textarea
  with a synced gutter; Tab inserts spaces) with an **Edit / Preview** toggle
  (Preview renders the Markdown) and a **Save** button (also `Ctrl/Cmd+S`).
  Unsaved edits prompt before leaving; an over-size or binary file opens
  read-only. Saving an Agent refreshes the composer's Agent menu.

Every read, write, and create is confined to a configured root and the
category's file pattern; the surface can never open or write an arbitrary file.

### 7. Ask-User prompt (in-thread)

When the agent calls the Ask-User Tool, an inline card appears in the thread
with the question and an input; the answer is sent back and the Turn resumes.
*(Depends on FR-T4; if not wired in v1, the Tool reports no console and the agent
proceeds.)*

## States

| State | Cue |
| --- | --- |
| Idle | composer focused, Send enabled. |
| Streaming | Stop button, blinking caret, live Activity hints. |
| Tool running | "Working… (using tools)" pill under the streaming Message. |
| Error | red inline card with the message + Retry. |
| Unauthenticated | Authenticate screen replaces the thread. |
| Empty | friendly empty-state with example prompts. |

## Accessibility

- Full keyboard nav; visible focus rings; `aria-live="polite"` on the streaming
  Message; sufficient contrast in both themes; respects
  `prefers-reduced-motion`.

## No-build constraint

Vanilla JS modules + a single CSS file with custom properties. Markdown
rendered by a tiny in-repo renderer or a single vendored, audited script under
`web/assets/vendor/`. No package manager, no bundler.
