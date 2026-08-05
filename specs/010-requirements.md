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
| FR-C9 | M | Let the user add Attachments (text and small binaries such as images, PDFs, .docx) to a Turn through the Attach button, drag-and-drop, or clipboard paste. Uploads land in the Workspace Folder when a Project is active; with no Project selected they fall back to an uploads folder in the data directory. Either way the agent is told the paths so its existing File Tool can read non-image files. |
| FR-C10 | S | Let the user search Conversations by title and Message text and jump to a match. Searching matches case-insensitively across the persisted store and returns the matching Conversations with a short snippet. |
| FR-C11 | S | Let the user pin a Conversation (pinned Conversations sort to the top) and archive a Conversation (archived Conversations are hidden from the main list behind a show-archived toggle). Both states persist across sessions. |
| FR-C12 | S | Let the user export a Conversation as a Markdown transcript (a download), with the title, each Message labelled by author, and per-Turn Usage. |
| FR-C13 | C | Let the user dictate a prompt by voice (speech-to-text) and have an assistant Message read aloud (text-to-speech), using the browser's built-in speech APIs with no extra dependency. The controls are shown only when the browser supports them. |
| FR-C14 | C | Let the user drop or paste files onto the composer as Attachments, equivalent to the Attach button. A text-only paste continues to insert text normally. |
| FR-C15 | S | Let the user regenerate the last assistant response: the Host Server truncates the Conversation to the last user Message and re-runs the Turn, streaming a fresh answer. |
| FR-C16 | S | Let the user edit a previous user Message and resend it: the Host Server truncates the Conversation to that Message and re-runs the Turn with the new text, discarding the Messages that followed. |
| FR-C17 | S | Extend the per-Conversation action menu: open a Conversation in a new browser window (deep link `/?c=<id>`), **Duplicate** it, mark it **Unread** / **Mark all as read** (with an unread dot + a "Mark N as read" control), assign an optional **Colour** label from a fixed palette, **Copy transcript** (Markdown) to the clipboard, and view read-only **Details** (created/updated/message count/model/colour, plus the accumulated **Usage** — cost, credits, and tokens summed across the Conversation's Messages). Keyboard on a focused row: Enter opens, F2 renames, Delete archives. Deletion itself is unchanged (the hover ✕). |
| FR-C18 | S | Give each Conversation a **Session Info** panel (like GitHub Copilot's): its accumulated cost (credits + $) and turn count, a **Context Window** gauge (the last Turn's per-round-trip prompt size — the Engine's summed `promptTokens` ÷ its tool-calling `iterations`, so the value reflects a single prompt rather than the billed sum across round-trips — against the Model's `maxContextWindowTokens`, with a reserved-for-response tail and an estimated Messages vs. System+tools breakdown), and a **Compact** action. Open it from a glanceable top-bar context meter or the Conversation action menu. **Compact** summarises the earlier replayed history into a briefing (a pure-reasoning Turn, Tools off), keeps recent Turns verbatim, and preserves the visible transcript; only what is replayed to the Engine shrinks, so the next Turn sends fewer tokens. |
| FR-C19 | S | **Automatically compact** a Conversation when its last Turn filled the Model context window to at least a configurable threshold. After a Turn, when auto-compaction is enabled and the measured occupancy (the last Turn's per-round-trip prompt size — `promptTokens` ÷ `iterations` — over `maxContextWindowTokens`) reaches the threshold, DeskPilot runs the same summarise-and-keep-tail Compact as FR-C18 (best-effort; a too-little-history reply is a silent no-op) so a long Conversation keeps working instead of overflowing the window. Every firing is announced with a toast and the visible transcript is preserved. Controlled by three Settings: an on/off toggle (default **on**), the threshold percent (50–95, default 80), and how many recent messages to keep verbatim (2–100, default 4). |

### Agent Tools & Permissions

| ID | Priority | Requirement |
| --- | --- | --- |
| FR-T1 | M | Expose all Engine Tool categories: Browsing, File, Terminal, Ask-User, User Tools. |
| FR-T2 | M | Provide a visible Permission switch per Tool category that maps 1:1 to the Engine `-Disable*` switches for the next Turn. |
| FR-T3 | M | Surface per-Turn Activity: files read/written, commands run, pages fetched, questions asked, tool calls. |
| FR-T4 | S | Route Ask-User into the UI: bundle related questions as a Questionnaire wizard with single-select, multi-select, and conditional free text; feed the submitted answers back into the same Turn. |
| FR-T5 | C | Manage User Tools (`Register-ShpTool`/`Unregister-ShpTool`) from the UI. |
| FR-T6 | S | When the selected Project is a Git repository, let the user undo the file changes a Turn made: revert tracked files the Turn wrote and remove files it newly created, after an explicit confirm. Confined to the Workspace Folder. |
| FR-T7 | S | When the selected Project is a Git repository, let the user view the Git diff of a file the Turn wrote, inline from the Activity panel. |
| FR-T8 | S | Show a **Changes** card under the newest assistant Message listing every file that Turn changed, with a per-file and total added/deleted line count and a plain-language status, and let the user **Keep** them (commit exactly those files with a short description) or **Undo** them. Confined to the Workspace Folder. |
| FR-T9 | S | Let the user open any changed file in a **Diff viewer** showing a unified diff with both old and new line numbers, step through the whole change set, and undo a single file. A new file is shown as all additions; a binary file says so. |
| FR-T10 | S | Show the number of uncommitted changes in the Git bar and let the user review them all, not only those from the newest Turn. |

### Branches and the server (Git Workbench)

| ID | Priority | Requirement |
| --- | --- | --- |
| FR-B1 | S | Provide a **Branch Wizard** that shows the current Branch, the Branch list with merged badges, and per-Branch **Switch** and **Delete** actions. |
| FR-B2 | S | Let the user **create** a Branch from a chosen starting point, optionally switching to it. Validate the name against Git's ref rules in plain language before Git sees it. |
| FR-B3 | S | Let the user **delete** a Branch safely: never the Default Branch; switch off it first when it is checked out; refuse an unmerged Branch with an explicit "delete anyway" instead of a dead end; make the remote delete a separate opt-in with its own confirm. |
| FR-B4 | S | Let the user **sync** with the server in plain language — get, send, or both — including publishing a Branch that has no upstream, and offering to set uncommitted changes aside and restore them around a pull. |
| FR-B5 | S | Report how many saves are waiting to be sent or received, and whether the working tree is dirty or a merge is unresolved. |
| FR-B6 | S | When a conflict appears outside the Merge Wizard, **generate a prompt** that asks the agent to resolve it, show it for review and editing, and send it only when the user chooses to. Also offer aborting the merge. |
| FR-B7 | M | Never let a Git call block the Host Server: networked Git runs with a timeout and with terminal prompting disabled, and DeskPilot stores no Git credentials. |

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
| FR-M6 | C | Send image Attachments through the Engine's native Vision input and support structured-output requests. |
| FR-M7 | S | Let the user record durable **Preferences** (the **User Profile** — an About-me note: role, writing style, recurring context) that are injected into every Turn's system prompt. Preferences persist across sessions and Conversations. |
| FR-M8 | C | Let the user insert a Prompt File's body into the composer with a `/` menu, filling any `{{variable}}` placeholders first, and reference a Project file by relative path with a `#` menu. |
| FR-M9 | C | Let the user mark **Reference files** (project-relative paths) that are injected into every Turn's system prompt so the agent always treats them as relevant and reads them with its File Tool on demand — a build-free alternative to vector retrieval. |
| FR-M10 | C | Provide a **command palette** (Ctrl/Cmd+K) and a few global keyboard shortcuts for common actions (new conversation, search, settings, customizations, theme, regenerate, export) and quick conversation jump. |
| FR-M11 | C | Let the user set a per-session **spend warning** (USD); show a one-time warning when the session's estimated cost crosses it (0 disables it). |
| FR-M12 | S | Maintain a persistent **Agent Memory** — durable, declarative notes the agent keeps about the user and their environment (conventions, tools, observed preferences, lessons learned) — injected into every Turn's system prompt as fenced reference background so past learning carries into new Conversations. Bounded to a fixed character budget (12,000 characters ≈ 3,000 tokens); the user can view, edit, and clear it. Distinct from the **User Profile** (FR-M7): the profile is what the *user states* about themselves; the memory is what the *agent learns*. |
| FR-M13 | S | Curate the Agent Memory two ways: **automatically** after a Turn (a throttled, best-effort, pure-reasoning pass that folds durable facts from the conversation into the memory — default on, announced with a toast, and toggleable), and **manually** on demand (an "update from this conversation" action). Learning writes declarative facts only, never records secrets or transient task state, consolidates to fit the budget, and never alters the visible transcript. |

### Settings

| ID | Priority | Requirement |
| --- | --- | --- |
| FR-S1 | M | Persist Settings (Model, Permissions, Projects and the selected Project, Agents folder and selected Agent, Skill/Instruction/Prompt roots, reasoning effort, show-thinking, tool-iteration cap, auto-compaction toggle/threshold/keep-recent, memory-learning toggle, update-check interval and include-previews toggle) to disk and load them on startup so the user's choices stick between sessions. |
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
| FR-X7 | C | Offer an opt-in **CopilotAtelier setup** from the Agent menu: after an explicit consent step that spells out what it changes, download the CopilotAtelier repository and run its `Setup-CopilotSettings.ps1` to link the `~/.copilot` Customization roots (agents, instructions, skills, prompts) so the Agent picker and Customizations surface fill with real content. Never a one-click action; the setup script runs in a console the user drives, and the auto-run is Windows only. |

### Usage & cost

| ID | Priority | Requirement |
| --- | --- | --- |
| FR-U1 | M | Show per-Turn token Usage, estimated USD cost, and Copilot credits. |
| FR-U2 | M | Show a **session** Usage summary (tokens, cost, credits, turns) that resets each time the Host Server starts. |
| FR-U3 | M | Track a **lifetime** Usage counter (credits, cost, tokens, turns) that persists to disk across sessions and is never reset automatically. |
| FR-U4 | M | Let the user reset the lifetime counter manually; record the date it has counted since. |
| FR-U5 | S | In the Usage panel, show the **tokens in / tokens out** split (prompt vs. completion) alongside the totals for both the session and lifetime counters, a **Top models** list (this session, ranked by tokens), and a 7-/14-/**30-day** credits-per-day chart. |

### Software updates

| ID | Priority | Requirement |
| --- | --- | --- |
| FR-UP1 | S | Check the PowerShell Gallery for a newer DeskPilot **periodically** (default every 5 minutes, configurable 1–1440) and **on demand** (a Check-for-updates button), off the accept thread so serving is never blocked. Offer the newest **full release** by default; consider **previews** only when the user opts in (`updateIncludePrereleases`) and the preview is strictly newer. Surface the result in the **web UI only** (a dismissible banner + a Settings status line) — never on the launcher console. |
| FR-UP2 | S | Apply an update only on **explicit user consent** (an Update-now action after a notice that discloses what will be installed). Installing updates **both** DeskPilot and the Engine (ShellPilot) from the Gallery into the CurrentUser scope; when DeskPilot is updated to a **preview**, ShellPilot previews are accepted too, otherwise both are pinned to stable. ShellPilot is then **force-reloaded live** so the Engine update takes effect at once; DeskPilot's own host code cannot hot-swap in-process, so it is applied by a one-click **Restart DeskPilot** relaunch (a fresh process that imports the updated modules and reuses the data directory, so Conversations carry over). |

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
