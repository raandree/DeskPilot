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
| Conversation | A user-visible chat thread with its own ordered Message history. May be **pinned** (sorted to the top of the list), **archived** (hidden from the main list behind a show-archived toggle), marked **Unread**, or given a **Colour** label. | session, chat (for the thread), room |
| Unread | A per-Conversation flag marking it as having content the user has not yet seen. Shown as a dot plus a bold title and cleared when the Conversation is opened or via **Mark all as read**. | notification, badge (loosely), new, seen |
| Duplicate (a Conversation) | Create an independent copy of a Conversation — its title, Messages, and history — as a brand-new Conversation that shares no state with the original. | fork, branch (that is a git Branch), clone (that is a repo Clone), copy (in UI copy) |
| Colour | An optional colour label a user assigns to a Conversation for lightweight organisation, drawn from a fixed palette and shown as a dot on the row. | tag, category, flag, label (in identifiers) |
| Turn | One user prompt plus the assistant's full response, including any Tool use. | round, exchange |
| Message | A single entry in a Conversation, authored by the user or the assistant. | post, line, bubble |
| Tool | An agent capability category: Browsing, File, Terminal, Ask-User, or a User Tool. | function, plugin, skill (a Tool is not a Skill) |
| Questionnaire | A bundled Ask-User wizard containing one or more ordered questions, optional answer choices, single- or multi-select behavior, and conditional free text. | survey, form, question card (for the bundled wizard) |
| Activity | The record of Tool use within a Turn: files read/written, commands run, pages fetched, questions asked. | log, trace (loosely) |
| Permission | A user-facing on/off switch governing one Tool category. | toggle, flag (in UI copy) |
| Model | The Copilot LLM identifier used for a Turn. | engine (that is the Engine), the AI |
| Skill | A VS Code Agent Skill (a SKILL.md) the Engine discovers via progressive disclosure. | plugin, extension, add-on |
| Instruction | A VS Code instruction file (*.instructions.md) the Engine can load on demand. | rule, prompt file |
| Workspace Folder | The working directory the Engine's File and Terminal tools operate in by default. | sandbox, root, cwd (in UI copy) |
| Project | A registered, named pointer to a Workspace Folder. Projects are listed in a registry; the selected Project's folder is the working directory for new Turns, and the last selected Project persists as the default. | workspace (for the registered entity), repo, site, directory (in UI copy) |
| Close (a Project) | Deselect the active Project so no Workspace Folder is active, while the Project stays registered. Persists across sessions and is distinct from Remove (which unregisters the Project). | deselect, unload, unset, remove (that unregisters), clear |
| Agent | A selectable persona defined by an `*.agent.md` file (YAML frontmatter + a Markdown body). The selected Agent's body becomes the Turn's system prompt. Agents are discovered under the Agents folder (defaulting to `~/.copilot/agents`). | persona (in identifiers), bot, assistant, role |
| Customization | An agent-shaping Markdown file the user can browse and edit in DeskPilot: an Agent, a Skill, an Instruction, or a Prompt File. Customizations are discovered under their configured roots and grouped by category in the Customizations surface. | resource, asset, add-on, customisation (spelling) |
| Prompt File | A reusable `*.prompt.md` file discovered under a Prompt root; one kind of Customization. | prompt (for the file), snippet, template |
| Task | A single tracked sub-step the agent plans and completes within a Turn. Has an id, a short action-oriented title, and a status of `not-started`, `in-progress`, or `completed`. | todo, step, item, checkbox |
| Task List | The ordered set of Tasks the agent maintains during one Turn; at most one Task is `in-progress`. Streamed live and persisted on the assistant Message. | todos, checklist, plan, TODO list |
| Preferences | A durable, user-authored note about the user (role, writing style, recurring context) injected into every Turn's system prompt. One per install; persists across Conversations and sessions. | profile, persona (that is an Agent), memory, about-me (in identifiers) |
| Reference File | A project-relative file path the user marks as always-relevant; its path (not its content) is injected into every Turn's system prompt so the agent reads it with its File Tool on demand. | upload, knowledge base, RAG doc |
| Attachment | A file added to one Turn through the Attach button, drag-and-drop, or clipboard paste. DeskPilot uploads it before sending the prompt; image Attachments are also passed to the Engine's native Vision input. | Reference File, Artifact, embedded file |
| Artifact | A previewable code block in an assistant Message — `html` or `svg` — that DeskPilot can render in a sandboxed frame. | canvas, widget, embed, component |
| Usage | The token counts, estimated USD cost, and Copilot credits reported for a Turn. | stats, metrics (loosely) |
| Save | Recording the Project's uncommitted files as one Git commit, so the work becomes part of the Project's history and can be sent to the server. DeskPilot's user-facing name for a commit. | commit (in UI copy), checkpoint (that is the pre-Turn restore point), backup, snapshot (that is the pre-Turn snapshot), stage |
| Save Message | The one-line description recorded with a Save. Prefilled from the change set, optionally written by the Model on request, and always editable before the Save happens. | commit message (in UI copy), comment, note, caption |
| Branch | A git branch inside a Project's repository. | fork (a fork is a separate repo), ref (loosely) |
| Default Branch | The repository's primary integration branch and the only Merge target: `origin/HEAD` if set, else a local `main`, else `master`. | trunk, mainline, master (when you mean the concept rather than the literal branch name) |
| Merge | Combining a source Branch into the Default Branch — fast-forward when possible, else a merge commit. | integrate, combine, sync |
| Merge Wizard | The multi-step DeskPilot UI that previews incoming commits, merges a Branch into the Default Branch, resolves conflicts via a Merge Plan, and cleans up the Branch for a non-expert. | merge dialog, merge tool (loosely) |
| Merge Plan | The AI's proposed, per-file resolution of a merge conflict, shown for the user's approval before any file is written. Distinct from a Task List. | conflict fix, resolution, patch, diff |
| Clone | Creating a local copy of a remote repository as a new Project. | checkout (that is switching Branches), download, pull, copy |
| New Project Wizard | The DeskPilot UI for creating a Project either by Clone or by choosing a local-only Workspace Folder. | add-project dialog, import wizard |
| Session Info | The per-Conversation panel showing its accumulated cost, the Context Window occupancy of the last Turn, an estimated breakdown of that context, and a **Compact** action. Opened from the top-bar context meter or the Conversation's action menu. Named after GitHub Copilot's "Session Info"; it does not rename the Conversation thread (see Conversation). | stats, dashboard, session (for the thread) |
| Context Window | The Model's maximum input size in tokens, and how much of it the last Turn used (the Engine-reported `promptTokens`). Shown as a gauge in Session Info and a compact meter in the top bar. | context length, window size, token budget (loosely) |
| Compact | Summarise a Conversation's earlier replayed history into a short briefing, keeping recent Turns verbatim, so future Turns send fewer tokens. The visible transcript is preserved. | compress (in UI copy), summarise, truncate, prune, forget |
| Auto-compaction | Running **Compact** automatically after a Turn when the Context Window occupancy reaches a user-set threshold, so a long Conversation keeps working without overflowing the Model window. Controlled by the `autoCompaction`, `compactionThreshold` and `compactionKeepRecent` Settings. Every firing is announced with a toast. | auto-compress, auto-summarise, auto-prune, context engine |
| Memory | DeskPilot's persistent, cross-Conversation memory injected into every Turn's system prompt. Has two parts: the **User Profile** and the **Agent Memory**. Not the same as the developer-facing `.memory-bank/` (DeskPilot's own project knowledge base used to *build* DeskPilot). | context, history, the memory bank (the dev knowledge base) |
| User Profile | The durable note the **user** writes about themselves (role, style, recurring context) — the `preferences` Setting — injected into every Turn. | preferences (in UI copy), bio, about-me |
| Agent Memory | Durable, declarative notes the **agent** curates about the user and their environment across Conversations (conventions, tools, observed preferences, lessons), bounded and injected into every Turn. Learned automatically (throttled) or edited by hand. | memory (bare), agent notes, the memory bank |
| CopilotAtelier | The sibling repository (`raandree/CopilotAtelier`) of curated Customizations (agents, skills, instructions, prompt files) that DeskPilot can download and register into `~/.copilot` via an opt-in, consent-gated **CopilotAtelier setup** in the Agent menu. | plugin pack, marketplace, extension store, the atelier (bare) |
| Update | Replacing the installed DeskPilot — and, in lock-step, the Engine (ShellPilot) — with a newer PowerShell Gallery release. DeskPilot checks for one periodically and on demand, but only ever installs on explicit user consent, and the new version takes effect on the next launch. | upgrade, patch, self-update (in UI copy) |
| Intercom | DeskPilot's two-way link to the operator's phone: it pushes a blocked question, a finished or failed job, and a stall warning to one allow-listed Telegram chat, and accepts answers, instructions and commands back. Off by default, and inert for any Project that has not opted in. | beacon, relay, remote control, bot, notifier, companion |
| Channel | The transport an Intercom speaks over — Telegram in v1. An Intercom speaks over a Channel; the two are not interchangeable. | transport (in UI copy), provider, connector |
| Check-in | One refresh of the live status message, which always states the time of the **next** check-in. A check-in time that has passed is how the operator detects that DeskPilot has stopped. | heartbeat (in UI copy), ping, keepalive |
| Keyboard | The row of tappable buttons Intercom attaches under a Channel message so a closed choice can be answered with one tap instead of typed. Offered for a single-select question and the `/chats` list; the written form always still works. | inline keyboard (in UI copy), menu, quick reply, chips, buttons (in identifiers) |
| Preview | A prerelease Gallery version of DeskPilot (or ShellPilot). Previews are considered only when the user opts in; the newest full release is otherwise the update target, and updating to a Preview also accepts a Preview Engine. | beta, nightly, dev build, prerelease (in UI copy) |
| Checkpoint | The pre-Turn snapshot made addressable from the transcript: a marker above a user Message offering to go back to the moment just before it was sent. Restoring one discards that Message and every later one, and puts back the files the discarded Turns wrote. | restore point, revert point, save point, rollback, snapshot (that is the underlying commit), Save (that is a Git commit) |
| Restore (a Checkpoint) | Going back to a Checkpoint: the Conversation is truncated, the discarded prompt returns to the composer, and the files those Turns wrote are put back. The user's own edits to other files are untouched. Reachable from the window and from Intercom's `/undo`. | roll back, rewind, revert (that is a Git revert), reset, undo (that is a single-file Undo) |

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
  (the `-DisableTodoList` switch, the `ShpProgress` records, `result.TodoList`).
  Everywhere else — code identifiers, SSE event, UI copy, docs — use **Task** /
  **Task List** (`task`, `tasks`, `taskList`, `taskTracking`).
- **Save vs. the `commit` field.** UI copy, docs, and prose use **Save**; the
  route, the helper, and the wire fields stay `commit` — `POST /api/git/commit`,
  `Invoke-DpGitCommit`, `committed`, `nothingToCommit` — because that is git's own
  vocabulary at the boundary. This mirrors the Colour / `color` note.
- **Save vs. Keep vs. Undo.** **Keep** accepts a pending DeskPilot change and
  stops tracking it; it writes nothing to Git. **Save** writes a commit, which is
  what makes the work durable and sendable. **Undo** puts a file back the way it
  was before DeskPilot touched it. Saving a file also ends its pending state, but
  Keeping one never commits it; never use the two words interchangeably.
- **Checkpoint vs. Undo vs. Save.** All three put files back, at different
  scopes. **Undo** reverts one pending file. A **Checkpoint** reverts everything
  a run of Turns wrote *and* rewinds the Conversation to before the prompt that
  started them — it is the only one of the three that touches the transcript.
  **Save** does the opposite: it makes the current state permanent. A Checkpoint
  restores only what DeskPilot wrote, never the whole folder, so hand edits the
  user made in the meantime survive; that is the same boundary the pending change
  set draws, and why a Checkpoint is not a `git reset`.
- **Default Branch vs. the literal name.** **Default Branch** is the *concept*
  (the only Merge target); the actual branch is named `main` or `master`. Use
  **Default Branch** in code, UI copy, and docs; only write `main`/`master` when
  naming a literal branch the user sees.
- **Merge Plan vs. Task List.** A **Merge Plan** is the AI's proposed conflict
  resolution (per-file content the user approves before any write). It is not a
  **Task List** (the in-Turn progress checklist) and not an **Activity** record.
- **Clone vs. checkout.** **Clone** creates a new local Project from a remote
  repository. Switching between existing Branches is a checkout, not a Clone.
- **Duplicate vs. Branch vs. Clone.** **Duplicate** copies a **Conversation**
  into a new Conversation. A **Branch** is a git branch inside a Project. A
  **Clone** makes a new Project from a remote repository. They are three
  different concepts; never call duplicating a Conversation “branching” or
  “cloning” it. The private helper is `Copy-DpConversation` because **Copy** is
  the approved PowerShell verb; the product term everywhere else is **Duplicate**.
- **Colour vs. the `color` field.** UI copy, docs, and prose use the British
  spelling **Colour**; the wire/JSON field and code identifiers use `color` to
  match CSS and JSON conventions. This mirrors the Task / `TodoList` boundary
  note — the anglicised term is canonical, the technical field name is an
  accepted boundary spelling.
- **Close vs. Remove vs. switch (a Project).** **Close** deselects the active
  Project — it stays registered, but no Workspace Folder is active. **Remove**
  unregisters a Project (it leaves the registry; the folder stays on disk).
  Switching selects a different already-registered Project. Use each verb
  precisely; never describe closing a Project as "removing" it, or vice versa.
- **Compact vs. the `Compress` verb.** UI copy, docs, and prose use **Compact**
  (matching GitHub Copilot's "Compact Conversation"); the private helper is
  `Compress-DpConversationHistory` because **Compress** is the approved PowerShell
  verb. This mirrors the Duplicate / `Copy-DpConversation` boundary note.
- **Auto-compaction vs. Compact.** **Compact** is the manual, user-invoked action
  (the Session Info button). **Auto-compaction** is the same summarisation fired
  automatically after a Turn once the Context Window crosses the threshold; both
  go through the one `POST /compact` route and the `Compress-DpConversationHistory`
  helper. Use **Compact** for the action/verb and **Auto-compaction** only for the
  automatic policy; never call the automatic firing "auto-compress".
- **Memory vs. the Memory Bank.** DeskPilot's runtime **Memory** (User Profile +
  Agent Memory, a feature for the end user) is a different thing from the developer
  `.memory-bank/` folder (the version-controlled project knowledge base an AI
  coding agent reads to *build* DeskPilot). Never conflate them; in product code,
  UI, and docs, **Memory** / **User Profile** / **Agent Memory** are the runtime
  feature, and `.memory-bank/` is only ever the dev knowledge base.
- **User Profile vs. Agent Memory.** The **User Profile** is what the *user states*
  about themselves (the manual `preferences` block); the **Agent Memory** is what
  the *agent learns* (curated automatically or by hand, its own `agent-memory.json`
  store). Both are injected every Turn but have different authors and stores; keep
  the terms distinct.
- **Attachment vs. Reference File.** An **Attachment** is uploaded for one Turn
  from the composer. A **Reference File** is a persistent Project setting whose
  path is injected into every Turn. An image Attachment also uses the Engine's
  native Vision input; a Reference File is only read on demand with the File Tool.
- **Session Info vs. Usage vs. Details.** **Usage** is the global credits/cost
  counter (this-session and all-time) in the sidebar. **Session Info** is
  per-Conversation: its accumulated cost plus its Context Window occupancy and the
  Compact action. The Conversation **Details** popover is a lighter read-only
  metadata card. Keep the three distinct. "Session" stays forbidden as a synonym
  for the Conversation *thread*; **Session Info** is only the name of this panel.
- **Context Window: measured vs. estimated.** The occupancy figure is the exact
  `promptTokens` the Engine reported for the last Turn; the per-component
  breakdown (Messages vs. System + tools) is a client-side estimate
  (~4 chars per token) because the Engine does not itemise the context. Always
  label the breakdown as estimated.
- **CopilotAtelier setup vs. Atelier health.** **CopilotAtelier setup** is the
  opt-in action in the Agent menu that downloads the **CopilotAtelier** repository
  and runs its `Setup-CopilotSettings.ps1` to provision the `~/.copilot` roots.
  **Atelier health** is the read-only Settings panel that reports whether those
  same roots resolve. One provisions; the other inspects. Use **CopilotAtelier**
  for the repository/feature and never call the setup a "plugin install" or
  "marketplace".
- **Preview vs. the `prerelease` field.** UI copy, docs, and prose use **Preview**
  for a prerelease Gallery version; the wire/JSON fields and code identifiers use
  `prerelease` to match the PowerShell Gallery boundary — `updateIncludePrereleases`,
  `targetIsPrerelease`, the `-AllowPrerelease` install flag, and
  `Invoke-DpSelfUpdate -IncludePrerelease`. This mirrors the Colour / `color`
  boundary note: the friendly term is canonical, the technical field name is an
  accepted boundary spelling.
- **Update vs. CopilotAtelier setup.** Both fetch first-party content over HTTPS
  on consent, but they are different: **Update** replaces the DeskPilot and
  ShellPilot **modules** from the PowerShell Gallery (`Install-Module`), while the
  **CopilotAtelier setup** provisions the `~/.copilot` Customization **roots** from
  a repository zip. Keep them distinct in code and copy.
- **Intercom is bidirectional.** The word normally suggests one-way signalling;
  here it is deliberately two-way — DeskPilot pushes *and* accepts instructions.
  Never describe it as a beacon, a notifier, or an alerting feature: those names
  hide the half that carries authority. **Beacon** was rejected precisely because
  it is both one-way and, in security tooling, the word for malware calling home.
- **Intercom vs. Channel vs. Check-in.** The **Intercom** is the feature. The
  **Channel** is what it speaks over (Telegram). A **Check-in** is one refresh of
  the live status message. Three distinct concepts; do not collapse them.
