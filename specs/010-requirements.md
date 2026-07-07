# 010 — Requirements

Priorities use MoSCoW: **M**ust, **S**hould, **C**ould, **W**on't (this release).

## Functional requirements

### Authentication

| ID | Priority | Requirement |
| --- | --- | --- |
| FR-A1 | M | Detect whether the Engine's Copilot token is present and report auth status to the UI. |
| FR-A2 | M | If unauthenticated, run the GitHub device-code flow and stream the user code + verification URL into the UI until login completes. |
| FR-A3 | S | Surface a clear error if authentication fails or times out, with a retry. |

### Conversations & messaging

| ID | Priority | Requirement |
| --- | --- | --- |
| FR-C1 | M | Create, list, open, and delete Conversations. |
| FR-C2 | M | Send a prompt as a Turn and stream the assistant's answer token-by-token (SSE). |
| FR-C3 | M | Persist each Conversation's Message history and replay it to the Engine via `-History` so follow-ups remember context. |
| FR-C4 | M | Isolate Conversations from one another (no history bleed). |
| FR-C5 | S | Auto-title a Conversation from its first prompt. |
| FR-C6 | S | Allow stopping a Turn in progress. |
| FR-C7 | M | Persist Conversations to disk so they survive Host Server restarts; load them on startup. |
| FR-C8 | M | Removing a Conversation deletes it from the persisted store as well as the running session. |
| FR-C9 | M | Let the user attach files (text and small binaries such as images, PDFs, .docx) to a Turn through an Upload button. Uploads land in the Workspace Folder and the agent is told their relative paths so its existing File Tool can read them. |
| FR-C10 | S | Let the user search Conversations by title and Message text and jump to a match. Searching matches case-insensitively across the persisted store and returns the matching Conversations with a short snippet. |
| FR-C11 | S | Let the user pin a Conversation (pinned Conversations sort to the top) and archive a Conversation (archived Conversations are hidden from the main list behind a show-archived toggle). Both states persist across sessions. |
| FR-C12 | S | Let the user export a Conversation as a Markdown transcript (a download), with the title, each Message labelled by author, and per-Turn Usage. |
| FR-C13 | C | Let the user dictate a prompt by voice (speech-to-text) and have an assistant Message read aloud (text-to-speech), using the browser's built-in speech APIs with no extra dependency. The controls are shown only when the browser supports them. |
| FR-C14 | C | Let the user drop files onto the composer to attach them, equivalent to the Attach button. |
| FR-C15 | S | Let the user regenerate the last assistant response: the Host Server truncates the Conversation to the last user Message and re-runs the Turn, streaming a fresh answer. |
| FR-C16 | S | Let the user edit a previous user Message and resend it: the Host Server truncates the Conversation to that Message and re-runs the Turn with the new text, discarding the Messages that followed. |

### Agent Tools & Permissions

| ID | Priority | Requirement |
| --- | --- | --- |
| FR-T1 | M | Expose all Engine Tool categories: Browsing, File, Terminal, Ask-User, User Tools. |
| FR-T2 | M | Provide a visible Permission switch per Tool category that maps 1:1 to the Engine `-Disable*` switches for the next Turn. |
| FR-T3 | M | Surface per-Turn Activity: files read/written, commands run, pages fetched, questions asked, tool calls. |
| FR-T4 | S | Route the Engine's Ask-User Tool question to the UI and feed the user's answer back. |
| FR-T5 | C | Manage User Tools (`Register-ShpTool`/`Unregister-ShpTool`) from the UI. |
| FR-T6 | S | When the selected Project is a Git repository, let the user undo the file changes a Turn made: revert tracked files the Turn wrote and remove files it newly created, after an explicit confirm. Confined to the Workspace Folder. |
| FR-T7 | S | When the selected Project is a Git repository, let the user view the Git diff of a file the Turn wrote, inline from the Activity panel. |

### Models, Skills, Instructions, behaviour

| ID | Priority | Requirement |
| --- | --- | --- |
| FR-M1 | M | List available Models and let the user pick one (per Conversation, defaulting from Settings). |
| FR-M2 | M | Let the user register named Projects (each a Workspace Folder), switch between them from a composer dropdown, and register new ones. The selected Project's folder is where the File/Terminal Tools default to. |
| FR-M2a | M | Persist the registered Projects and the selected Project; the last selected Project is the default working folder for a new prompt and survives across sessions. No two Projects may share a name or folder path. |
| FR-M2b | M | Let the user **close** the active Project (deselect it) so no Workspace Folder is active. Closing keeps the Project registered (distinct from removing it); the file explorer collapses and File/Terminal Tools fall back to no default folder until a Project is selected again. The closed state persists across sessions. |
| FR-M3 | S | Let the user attach Skill roots, Instruction roots and Prompt roots for progressive-disclosure discovery, defaulting to `~/.copilot/skills`, `~/.copilot/instructions` and `~/.copilot/prompts`. |
| FR-M4 | S | Let the user set reasoning effort and a "show thinking" toggle. |
| FR-M5 | S | Let the user pick an Agent (a persona from an `*.agent.md` file under an Agents folder, defaulting to `~/.copilot/agents`); the selected Agent's body becomes the Turn's system prompt. |
| FR-M6 | C | Support image (vision) attachments and structured-output requests. |
| FR-M7 | S | Let the user record durable **Preferences** (an About-me note: role, writing style, recurring context) that are injected into every Turn's system prompt. Preferences persist across sessions and Conversations. |
| FR-M8 | C | Let the user insert a Prompt File's body into the composer with a `/` menu, filling any `{{variable}}` placeholders first, and reference a Project file by relative path with a `#` menu. |
| FR-M9 | C | Let the user mark **Reference files** (project-relative paths) that are injected into every Turn's system prompt so the agent always treats them as relevant and reads them with its File Tool on demand — a build-free alternative to vector retrieval. |
| FR-M10 | C | Provide a **command palette** (Ctrl/Cmd+K) and a few global keyboard shortcuts for common actions (new conversation, search, settings, customizations, theme, regenerate, export) and quick conversation jump. |
| FR-M11 | C | Let the user set a per-session **spend warning** (USD); show a one-time warning when the session's estimated cost crosses it (0 disables it). |

### Settings

| ID | Priority | Requirement |
| --- | --- | --- |
| FR-S1 | M | Persist Settings (Model, Permissions, Projects and the selected Project, Agents folder and selected Agent, Skill/Instruction/Prompt roots, reasoning effort, show-thinking, tool-iteration cap) to disk and load them on startup so the user's choices stick between sessions. |
| FR-S2 | S | Let the user back up all Settings to a JSON file and restore them from one (restore is a full replace onto defaults). |
| FR-S3 | S | Show a collapsible file explorer of the selected Project's folders and files; collapsed and not expandable when no Project is selected. |
| FR-S4 | C | Show an **Atelier health** panel: whether each configured Customization root (`~/.copilot/{agents,skills,instructions,prompts}` by default) resolves, how many Customizations were discovered in each, and a flag when a root is missing or an unreadable reparse point. |

### Customizations (manage AI resources)

| ID | Priority | Requirement |
| --- | --- | --- |
| FR-X1 | M | List the Customizations discovered under the configured roots, grouped by category (Agents, Skills, Instructions, Prompt Files) with a per-category count and a per-item name + description, like a customization library. |
| FR-X2 | M | Open a Customization in an editor that shows line numbers, let the user edit its text, and save it back to disk; an over-size or binary file opens read-only. |
| FR-X3 | S | Create a new Customization in a configured root from a starter scaffold, then open it in the editor. |
| FR-X4 | M | Confine every Customization read, write, and create to a configured root and the category's file pattern, so the surface can never read or write an arbitrary file. |
| FR-X5 | C | Preview a Customization's rendered Markdown alongside the editor. |
| FR-X6 | C | Explain a Customization in plain language: open a new Conversation pre-filled with the file's content and a request to explain it, then send. |

### Usage & cost

| ID | Priority | Requirement |
| --- | --- | --- |
| FR-U1 | M | Show per-Turn token Usage, estimated USD cost, and Copilot credits. |
| FR-U2 | M | Show a **session** Usage summary (tokens, cost, credits, turns) that resets each time the Host Server starts. |
| FR-U3 | M | Track a **lifetime** Usage counter (credits, cost, tokens, turns) that persists to disk across sessions and is never reset automatically. |
| FR-U4 | M | Let the user reset the lifetime counter manually; record the date it has counted since. |

### Generative UI

| ID | Priority | Requirement |
| --- | --- | --- |
| FR-G1 | C | When an assistant Message contains a fenced `html` or `svg` code block (an **Artifact**), offer to preview it rendered in a sandboxed, script-isolated frame. No third-party rendering library is loaded (keeps the UI build-free); unsupported diagram languages fall back to the existing code block. |

## Non-functional requirements

| ID | Priority | Requirement |
| --- | --- | --- |
| NFR-1 | M | **Local-first.** Host Server binds to `127.0.0.1` by default; never a public interface without an explicit, documented opt-in plus auth. |
| NFR-2 | M | **Zero toolchain for users.** No npm/build; the UI is static files served by the Host Server. Only PowerShell 7 + a browser required. |
| NFR-3 | M | **Approachable UI.** Plain language, one primary action at a time, a calm, conventional chat layout; usable without terminal knowledge. |
| NFR-4 | M | **Transparency.** Tool use and cost are always visible after a Turn; nothing destructive occurs without the matching Permission on. |
| NFR-5 | S | **Resilience.** A failed Turn surfaces as a visible error and never corrupts Conversation history. |
| NFR-6 | S | **Responsiveness.** First streamed token appears as soon as the Engine emits it; the UI stays interactive during a Turn. |
| NFR-7 | S | **Testability.** Host Server helpers (routing, settings, SSE framing, parameter assembly) are unit-tested with Pester. |
| NFR-8 | C | **Portability.** Runs on Windows, macOS, Linux wherever PowerShell 7 and the Engine run. |

## Acceptance scenarios

1. **First run.** With no cached token, the UI shows an Authenticate screen,
   displays the device code, and transitions to the chat once login completes.
2. **Simple ask.** "Explain X in two sentences" streams an answer; Usage shows
   tokens and cost.
3. **Tool task.** With File Permission on and a Workspace Folder set,
   "Summarise every .md here and write summary.md" reads the files, writes the
   file, and lists both in the Activity panel.
4. **Permission off.** With Terminal Permission off, a prompt that would run a
   command instead explains it cannot, and no command appears in Activity.
5. **Isolation.** Two Conversations about different topics do not leak context.
