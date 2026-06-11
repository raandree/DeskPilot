# Glossary — Ubiquitous Language

This table is the single source of truth for DeskPilot terminology. Use the
**Term** column everywhere: code identifiers, comments, tests, UI copy, docs,
and commit messages. Never introduce a word from **Don't say**. If you need a
word for a concept that is not here, propose a new row rather than inventing a
synonym.

| Term | Means | Don't say |
| ------ | ------- | ----------- |
| DeskPilot | The product: a local desktop-style GUI that fronts the Engine to give non-technical users the full GitHub Copilot agent toolset. | the app, the tool, the GUI (in identifiers) |
| Host Server | The PowerShell HTTP + SSE process that serves the web UI and bridges requests to the Engine. | backend, web server, API (loosely) |
| Engine | ShellPilot — the PowerShell module that talks to GitHub Copilot. | the model, the API, the SDK, Copilot (for the module) |
| Engine Runspace | The single long-lived PowerShell runspace with the Engine imported, where every Turn executes. | thread, worker, background job |
| Conversation | A user-visible chat thread with its own ordered Message history. May be **pinned** (sorted to the top of the list) or **archived** (hidden from the main list behind a show-archived toggle). | session, chat (for the thread), room |
| Turn | One user prompt plus the assistant's full response, including any Tool use. | round, exchange |
| Message | A single entry in a Conversation, authored by the user or the assistant. | post, line, bubble |
| Tool | An agent capability category: Browsing, File, Terminal, Ask-User, or a User Tool. | function, plugin, skill (a Tool is not a Skill) |
| Activity | The record of Tool use within a Turn: files read/written, commands run, pages fetched, questions asked. | log, trace (loosely) |
| Permission | A user-facing on/off switch governing one Tool category. | toggle, flag (in UI copy) |
| Model | The Copilot LLM identifier used for a Turn. | engine (that is the Engine), the AI |
| Skill | A VS Code Agent Skill (a SKILL.md) the Engine discovers via progressive disclosure. | plugin, extension, add-on |
| Instruction | A VS Code instruction file (*.instructions.md) the Engine can load on demand. | rule, prompt file |
| Workspace Folder | The working directory the Engine's File and Terminal tools operate in by default. | sandbox, root, cwd (in UI copy) |
| Project | A registered, named pointer to a Workspace Folder. Projects are listed in a registry; the selected Project's folder is the working directory for new Turns, and the last selected Project persists as the default. | workspace (for the registered entity), repo, site, directory (in UI copy) |
| Agent | A selectable persona defined by an `*.agent.md` file (YAML frontmatter + a Markdown body). The selected Agent's body becomes the Turn's system prompt. Agents are discovered under the Agents folder (defaulting to `~/.copilot/agents`). | persona (in identifiers), bot, assistant, role |
| Customization | An agent-shaping Markdown file the user can browse and edit in DeskPilot: an Agent, a Skill, an Instruction, or a Prompt File. Customizations are discovered under their configured roots and grouped by category in the Customizations surface. | resource, asset, add-on, customisation (spelling) |
| Prompt File | A reusable `*.prompt.md` file discovered under a Prompt root; one kind of Customization. | prompt (for the file), snippet, template |
| Task | A single tracked sub-step the agent plans and completes within a Turn. Has an id, a short action-oriented title, and a status of `not-started`, `in-progress`, or `completed`. | todo, step, item, checkbox |
| Task List | The ordered set of Tasks the agent maintains during one Turn; at most one Task is `in-progress`. Streamed live and persisted on the assistant Message. | todos, checklist, plan, TODO list |
| Preferences | A durable, user-authored note about the user (role, writing style, recurring context) injected into every Turn's system prompt. One per install; persists across Conversations and sessions. | profile, persona (that is an Agent), memory, about-me (in identifiers) |
| Reference File | A project-relative file path the user marks as always-relevant; its path (not its content) is injected into every Turn's system prompt so the agent reads it with its File Tool on demand. | attachment, upload, knowledge base, RAG doc |
| Artifact | A previewable code block in an assistant Message — `html` or `svg` — that DeskPilot can render in a sandboxed frame. | canvas, widget, embed, component |
| Usage | The token counts, estimated USD cost, and Copilot credits reported for a Turn. | stats, metrics (loosely) |

## Notes

- **Conversation vs. session.** The Engine has its own internal "session" state
  (selected model, running chat, registered tools). DeskPilot deliberately
  avoids the word "session" at the product level and uses **Conversation** for
  the user-visible thread to prevent collision. Each Conversation carries its
  own history and is replayed to the Engine via its `-History` parameter.
- **Tool vs. Skill.** A **Tool** is a built-in agent capability category (or a
  User Tool exposed from a PowerShell command). A **Skill** is a Markdown
  knowledge file the agent loads on demand. They are different concepts; do not
  conflate them.
- **Engine vs. Model.** The **Engine** is ShellPilot (the transport). The
  **Model** is the LLM id (e.g. `claude-opus-4.8`) chosen per Turn.
- **Prompt vs. Prompt File.** A user's chat input is a **prompt** (lower case,
  the text of a Turn). A **Prompt File** is a saved, reusable `*.prompt.md`
  Customization. Keep the two distinct: never call a Prompt File just a
  "prompt" in identifiers or UI copy.
- **Customization vs. the four kinds.** **Customization** is the umbrella term
  for the editable files DeskPilot manages; each concrete file is still an
  **Agent**, **Skill**, **Instruction**, or **Prompt File**. Use the specific
  term when you mean one kind, and **Customization** only for the umbrella.
- **Task / Task List vs. the Engine boundary.** DeskPilot's **Task** and **Task
  List** map onto ShellPilot's built-in `manage_todo_list` tool and its result
  `TodoList` member. Those two identifiers are third-party names from the Engine
  boundary and are kept verbatim only where DeskPilot reads them off the Engine
  (the `-EnableTodoList` switch, the `ShpProgress` records, `result.TodoList`).
  Everywhere else — code identifiers, SSE event, UI copy, docs — use **Task** /
  **Task List** (`task`, `tasks`, `taskList`, `taskTracking`).
