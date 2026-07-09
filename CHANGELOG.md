# Changelog

All notable changes to DeskPilot are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Set up CopilotAtelier from the Agent menu.** The Agent dropdown has a new
  **Set up CopilotAtelier…** action that provisions the
  [CopilotAtelier](https://github.com/raandree/CopilotAtelier) customization set —
  the curated agents, skills, instructions and prompt files that feed the very
  menu it lives in. Because CopilotAtelier is a repository rather than an
  installable module, DeskPilot downloads it (a zip of the `main` branch over
  HTTPS from the fixed first-party URL, extracted under the data directory) and
  runs its `Setup-CopilotSettings.ps1`, which links
  `~/.copilot/{agents,instructions,skills,prompts}` to a synced copy. It is
  deliberately **not a one-click action**: choosing the menu item first opens a
  consent dialog that spells out exactly what the script changes (the `~/.copilot`
  junctions, VS Code `settings.json`/`keybindings.json`, and the
  `COPILOT_ALLOW_ALL` user environment variable) before anything is downloaded or
  run, and the script then runs in a visible PowerShell console the user drives so
  its own safety prompts (OneDrive account choice, replacing a non-empty folder)
  work. Windows only — the script uses NTFS junctions; on other platforms the
  files are fetched for a manual run. New `POST /api/atelier/setup` route and
  `Get-DpAtelierSource` / `Invoke-DpAtelierSetup` helpers (+4 unit tests).
- **The Agent list now refreshes without a restart.** Agents that appear after
  startup — most notably from the new CopilotAtelier setup, which runs in a
  separate console — now show up in the Agent menu on their own. The SPA
  re-checks the list on a short interval and whenever the window regains focus or
  the tab becomes visible (so returning from the setup console refreshes it), and
  `GET /api/agents` now adopts the conventional `~/.copilot/agents` folder the
  moment it exists even if it was absent at startup (new `Resolve-DpAgentsRoot`
  helper), so a selected Agent also reaches the Turn. Previously the Agents folder
  was resolved once at startup, so a freshly-created `~/.copilot/agents` (e.g. the
  CopilotAtelier junction) stayed invisible until DeskPilot was restarted. Polling
  was chosen over a server-side folder watcher to fit the single-threaded,
  no-persistent-SSE Host Server. (+3 unit tests.)
- **Publishable from the PowerShell Gallery, with the web UI bundled.** The
  DeskPilot web UI now ships inside the module (ModuleBuilder `CopyPaths`), so
  `Install-Module DeskPilot; Start-DeskPilot` serves the full interface from the
  installed module with no build step and nothing extra to download. The shipped
  `Start-DeskPilot` resolves its assets internally (`$PSScriptRoot/web`) — the
  public `-WebRoot` parameter is gone — and fails fast with a clear message if the
  bundle is missing or incomplete; a source checkout and the tests serve
  `source/web` via the `DESKPILOT_WEB_ROOT` environment variable so UI edits still
  hot-reload without a rebuild. ShellPilot stays resolved at runtime by
  `Resolve-DpEngineModule` (not a hard manifest dependency, so import never fails
  when the engine is absent), and the manifest metadata (author,
  project/license/icon URIs, description, tags) is filled in for the Gallery
  listing. A fail-silent
  launch-time check reports when a newer DeskPilot is available on the Gallery.
  Added an MIT `LICENSE`, Gallery/CI README badges, a new `Get-DpUpdateNotice`
  helper, and web-asset guard tests (bundle presence, Linux case-sensitivity of
  asset references, and a no-secrets scan). The `web/` folder was relocated to
  `source/web/`.
- **Persistent memory (DeskPilot learns who you are).** DeskPilot now carries
  durable memory across conversations, injected into every turn. Two parts: a
  **User profile** — the note you write about yourself (the existing preferences,
  now framed as your profile, up to 8,000 characters) — and a new agent-curated
  **Agent memory** — durable, declarative facts the agent keeps about you and your
  environment (conventions, tools, observed preferences, lessons), up to 12,000
  characters. Both are shown as fenced *reference notes* in the system prompt so a
  recalled fact is never mistaken for a new instruction. The agent keeps its memory
  up to date two ways: **automatically** (a throttled, best-effort background step
  after some turns — default on, announced with a toast, one toggle to disable) and
  **manually** (an "Update from this conversation" button). Learning writes facts
  only, never secrets or one-off task state, and never changes your visible
  messages. Manage it all in **Settings → Memory**: view, edit, or clear either
  store, with a live character/budget count. New endpoints `GET`/`PUT /api/memory`
  and `POST /api/memory/learn`; new helpers `Get-DpMemoryLimits`,
  `Import-DpMemoryStore`, `Save-DpMemoryStore`, `New-DpMemoryPrompt`,
  `ConvertFrom-DpMemoryResult`, `Get-DpMemoryPayload`; a new `agent-memory.json`
  store and a `memoryLearning` setting (+17 unit tests).
- **Automatic conversation compaction (Memory & context).** When a conversation
  fills most of the model's context window, DeskPilot can now summarise its earlier
  turns automatically so it keeps working instead of overflowing — the same
  summarise-and-keep-recent **Compact** it already offered, run for you after a turn
  once the context passes a threshold you set. Your visible messages are always
  kept, and every automatic compaction is announced with a toast. New **Memory &
  context** settings: an on/off toggle (default **on**), a **Compact when context
  reaches** percentage (50–95, default 80), and **Recent messages to keep in full**
  (2–100, default 4). The same keep-recent setting now also drives the manual
  Compact action. No new endpoint — auto-compaction reuses
  `POST /api/conversations/{id}/compact`. The Session Info panel shows a one-line
  indicator when auto-compaction is on. (+6 unit tests.)
- **Richer Usage panel.** The credits/usage popover now shows the **tokens in /
  tokens out** split (prompt vs. completion) for both the session and all-time
  counters, a **Top models** list for the session (ranked by tokens), and the
  credits-per-day chart gained a **30-day** range alongside 7d and 14d. All from
  data already tracked — no extra cost or Engine change.
- **Session info + Compact conversation (like GitHub Copilot).** Each conversation
  now has a **Session Info** panel — opened from a glanceable **context meter**
  pill in the top bar or the **⋯** menu — showing the conversation's accumulated
  cost (credits and $) and turn count, and a **Context Window** gauge: how much of
  the model's context window the last turn used, with a hatched *reserved for
  response* tail and an estimated split into **Messages** vs. **System + tools**.
  The context figure is measured exactly from the Engine's reported `promptTokens`;
  the per-part breakdown is a labelled client-side estimate. A **Compact
  conversation** button summarises the earlier turns into a short briefing so
  future turns send far fewer tokens — your visible messages stay intact; only what
  is replayed to the model shrinks. New endpoint
  `POST /api/conversations/{id}/compact` (runs a pure-reasoning turn with all tools
  disabled) and a new `compactedUtc` conversation field. New helpers
  `New-DpCompactionPrompt`, `ConvertFrom-DpCompactionResult`, and
  `Compress-DpConversationHistory` (+16 unit tests).
- **A richer conversation menu.** The per-conversation **⋯** menu is now grouped
  into clear sections with several new actions: **Open in new window** (opens the
  conversation in a separate browser window via a `/?c=<id>` deep link),
  **Duplicate** (an independent copy of the title, messages, and history),
  **Mark as unread** / **Mark as read** with an unread dot, a bold title, and a
  **Mark N as read** control under the list, an optional **Colour** label from a
  fixed palette (shown as a dot on the row), **Copy transcript** (the Markdown
  transcript straight to the clipboard), and **Details** (a read-only popover with
  the created/updated times, message count, model, colour, and the accumulated
  cost, credits, and tokens for the conversation). Focused rows also
  support keyboard shortcuts: **Enter** opens, **F2** renames, **Delete** archives.
  Deleting a conversation is unchanged (the hover **✕**). New endpoints
  `POST /api/conversations/{id}/duplicate` and `POST /api/conversations/read-all`,
  and new `unread`/`color` fields on the conversation summary.
- **Automatic conversation titles.** A brand-new conversation is now renamed from
  the generic "New conversation" to a concise, few-word AI summary of your first
  message — the way GitHub Copilot names a new chat (for example "Stop button
  malfunction" or "Merge changes to main"). The title fills in on its own a moment
  after the first reply; renaming a conversation yourself **locks** the name so it
  is never overwritten. Backed by a new best-effort
  `POST /api/conversations/{id}/title` endpoint that runs a pure-reasoning Turn
  with all Tools disabled to summarise the first prompt.
- **Close the active project.** The composer's project menu now offers **Close
  project** whenever a project is active, and the Settings drawer's project list
  shows a **Close** action on the selected project. Closing deselects the project
  so no working folder is active — the file explorer collapses and the agent's
  File/Terminal tools fall back to no default folder — while leaving the project
  registered (unlike **Remove**, which unregisters it). The closed state persists
  across sessions. Previously you could only switch to another project or create a
  new one, with no way back to a no-project state.
- **Branch Merge Wizard — merge a branch into main/master without the command
  line.** The project file explorer's Git bar now shows, for every branch, whether
  it is already merged into the **Default Branch** (a ✓ badge) or not yet merged
  (a ❗ badge), with a hover explanation and a legend; remote-only branches are
  listed and marked. A new **“Merge into &lt;default&gt;…”** button opens a guided,
  step-by-step wizard that: previews the incoming commits (the delta); merges
  (fast-forward when possible, otherwise a merge commit); offers a one-click fix
  when the working tree is dirty or the Default Branch is behind the server
  (auto-stash + update, then merge); and, on a **merge conflict**, hands off to the
  AI to propose a **Merge Plan** that you review before anything is written
  (binary files get a simple keep-mine / keep-theirs choice). After a successful
  merge it offers to delete the local branch, and — behind a separate, explicit
  confirmation — to push the Default Branch and delete the branch on the server
  using your existing Git sign-in. Every merge can be undone within the wizard.
  Backed by new endpoints under `/api/git/*` (`branches`, `merge/preview`, `merge`,
  `merge/plan`, `merge/apply`, `merge/abort`, `merge/undo`, `cleanup`), all
  confined to the selected Project's folder and run via a no-shell process call.
  The conflict-resolution Turn runs with all Tools disabled. Specs `070`
  (Merge Wizard) and `080` (Clone Wizard) capture the signed-off design.

### Changed

- **Smoother, faster live streaming.** The assistant's reply now streams to the
  browser more smoothly and with less delay. The Host Server forwards streamed
  tokens on a ~10 ms cycle instead of 40 ms and coalesces a burst of tokens into a
  single update, so text appears fluidly rather than in visible chunks. The file
  explorer's automatic 5-second refresh is also paused while a turn is streaming, so
  its directory and Git scan can no longer briefly stall the token stream (it
  refreshes once when the turn ends, as before). The Stop button and the final
  answer text are unchanged.
- **Settings are now organised into tabs.** The Settings drawer's fields are
  grouped into six tabs — **General**, **Permissions**, **Projects**,
  **Customizations**, **Memory & context**, and **Engine & data** — shown as a
  sticky pill strip at the top of the drawer, so it stays easy to navigate as
  settings grow instead of one long scroll. Only the active tab's fields are
  shown; every setting keeps working exactly as before. The strip follows the
  WAI-ARIA tablist pattern (Left/Right and Home/End move between tabs, and it
  wraps to two rows in a narrow window).
- **Attach files without a project.** The **Attach** button (and drag-and-drop)
  no longer requires a project to be selected. When a project is active, uploads
  land in its working folder as before; with no project selected they are saved
  to an `uploads` folder in DeskPilot's data directory, and the agent is given
  their full paths so it can read them with its File tool. Previously attaching a
  file without a project showed *"Select or register a project before attaching
  files."* and did nothing — which conflicted with the new ability to close a
  project and work without one.
- **The file explorer now refreshes automatically.** It updates on its own when
  the window or tab regains focus, when the tab becomes visible again, and on a
  gentle interval while it is open — so files an agent (or you) create, change, or
  delete on disk appear without clicking the refresh button. Automatic refreshes
  are silent (no flicker) and preserve which folders you have expanded and your
  scroll position, and they pause while you are interacting with the tree or the
  branch dropdown so nothing is yanked out from under you.
- **Build system: converted to the Sampler framework.** DeskPilot is now built
  with [Sampler](https://github.com/gaelcolas/Sampler) (ModuleBuilder,
  InvokeBuild, Pester 5, PSScriptAnalyzer, GitVersion). Module source moved from
  `src/DeskPilot/` to `source/`; the module builds into
  `output/module/DeskPilot/<version>/` with the version stamped from git by
  GitVersion. Build with `./build.ps1 -ResolveDependency -Tasks build` and test
  with `./build.ps1 -Tasks test`. Tests reorganised into `tests/QA` (module
  quality gates) and `tests/Unit`; the suite is green at 207 tests.
  `Start-DeskPilot.ps1` now builds on first run and imports the built module.
  This prepares DeskPilot for publishing to the PowerShell Gallery (the actual
  publish is gated to a later phase).
- **CI: added a GitHub Actions pipeline (`.github/workflows/ci.yml`).** Built from
  ShellPilot's pipeline as the template: build + package (GitVersion), a Linux/
  Windows/macOS test matrix on PowerShell 7, and a deploy job (on pushes to `main`
  and `v*` tags) that publishes to GitHub and the PowerShell Gallery and raises a
  changelog PR. Sampler/GitVersion produce a prerelease for `main` builds
  (installable with `Install-Module DeskPilot -AllowPrerelease`) and a stable
  release for a `v1.0.0`-style tag. Publishing stays dormant until the
  `GalleryApiToken`/`GitHubToken` repository secrets are configured.
- **Engine resolution: download ShellPilot from the PowerShell Gallery.** The
  Engine is now resolved by a new `Resolve-DpEngineModule` helper — an explicit
  `-EngineModulePath`, an already-installed `ShellPilot` module on the module
  path, or, when neither is found, a fresh install from the PowerShell Gallery
  into the CurrentUser scope (preview/prerelease versions allowed) — then
  imported by name. This replaces the previous probe of a hardcoded local build
  path (`V:/Git/ShellPilot/output/module/ShellPilot`), so DeskPilot now works on
  any machine without first building ShellPilot from source. The launcher prints
  a one-line note when a download happens.
- **Brand: theme-aware floated logo in README.** Replaced the small right-corner
  mark with the full DeskPilot lockup floated left (`<picture>` switching by
  `prefers-color-scheme`). Generated two transparent variants
  (`assets/dp-logo-on-light.png`, `assets/dp-logo-on-dark.png`) from the
  design-board source: navy `#06172A` wordmark + teal `#067E7D` "Pilot" accent
  for light themes; cream `#EAF1F8` wordmark + bright teal `#2DD4BF` accent for
  dark. Both 32bpp ARGB, auto-cropped, corner alpha 0. Existing in-app marks
  (`web/assets/logo-mark*.png`, `logo-full*.png`) are untouched. Added
  `.gitattributes` to mark `*.png binary`.

### Fixed

- **Sign-in now works on a clean machine.** On a machine that had never signed in
  before, completing the GitHub device-code flow left you stuck on *"Sign-in did
  not complete. Try again."* — every attempt looped without ever entering the app.
  The cause: the engine (ShellPilot) renamed the file it caches your sign-in token
  in from `.copilot-demo-token` to `.shellpilot-token` (in 0.2.1), but DeskPilot
  still checked the old name, so it never saw the token the engine had just
  written. DeskPilot no longer hardcodes that filename — it asks the engine for the
  path it actually uses — so sign-in is recognised regardless of the engine's token
  filename (and machines already signed in with an older engine keep working). If
  you hit this, just sign in once more; it now completes.
- **The model's Thinking is now readable — line breaks are preserved.** When you
  show the model's thinking, its reasoning is streamed to the browser as it is
  produced. Each line the engine writes arrived without its trailing line break, so
  the browser glued distinct thoughts together into one run-on wall of text (for
  example *"…before I consolidate.GitHub code search needs auth."*). DeskPilot now
  re-attaches the line break to each complete line the engine writes, so the
  Thinking pane — and the streamed answer — keep their paragraphs and line breaks.
  Streamed answer tokens are unaffected (they concatenate exactly as before).
- **The Agents list no longer errors on an inaccessible agents folder.**
  `Get-DpAgentList` probed the configured Agents root with `Test-Path`; if the root
  pointed at a drive or path that denies access (for example a restricted mapped
  drive), that probe could throw instead of returning an empty list. It now
  suppresses the probe error and returns no agents, matching the function's
  documented contract ("empty when the root is unset or missing").
- **The "Working…" indicator now always animates.** The spinner shown next to
  *Working…* while a turn is running could appear frozen — a static ring — for
  anyone who has operating-system animations turned off (on Windows: Settings →
  Accessibility → Visual effects → **Animation effects**). A global "reduce
  motion" style rule had switched off every animation, including this activity
  indicator, so it read as though nothing was happening. The spinner now keeps
  rotating whenever a turn is running — a smooth, continuous circle (a touch
  slower when reduced motion is enabled) rather than a flash — so it is always
  clear that DeskPilot is working.
- **A transient sign-in hiccup no longer fails a turn.** Occasionally the very
  start of a turn failed with *"Session token exchange failed … 403 (Forbidden)"*
  and you had to stop and resend. That step — exchanging your GitHub sign-in for a
  short-lived Copilot token, which the engine does at the start of every turn —
  intermittently fails and then succeeds on a retry. DeskPilot now retries it
  automatically (a few times, with a short back-off) before any answer has begun
  streaming, so the blip is invisible and nothing is ever duplicated. A genuinely
  expired sign-in is not retried — it still prompts you to sign in again.
- **The conversation actions menu now fits its contents.** The per-conversation
  "…" menu (Pin, Archive, Rename, Export) was rendered far too large — about as
  wide as a dialog and stretched down most of the window — because it inherited
  the base popover's fixed width and bottom anchor while being positioned from the
  top. It now sizes to the items shown.
- **An expired sign-in now offers a clear way back in.** When the cached GitHub
  Copilot sign-in expired, the model dropdown showed *"(sign in to load models)"*
  with no obvious next step: the token file still existed, so the app had already
  started and the sign-in screen was skipped, leaving an inexperienced user stuck.
  DeskPilot now recognises an expired or missing sign-in (the model list responds
  with a specific "sign in again" instead of a generic engine error) and
  automatically reopens the sign-in screen in a **"Your sign-in has expired"** mode
  that runs a fresh GitHub device-code flow. Previously a re-sign-in silently did
  nothing, because a stale token file made it report *"already signed in"* without
  actually re-authenticating; the flow is now forced (`Initialize-Shp -Force`), and
  the **Re-authenticate** button in Settings uses the same forced flow. Transient
  network hiccups are not mistaken for an expired sign-in. +9 unit tests.
- **The Stop button now actually stops a running turn.** Clicking **Stop** (or
  pressing Send while a turn is streaming with an empty composer) had no effect:
  the Host Server handles requests one at a time on a single thread, and a running
  turn held that thread for its whole duration, so the stop request waited
  unhandled in the connection backlog until the turn had already finished on its
  own. The streaming loop now services pending requests between polls, so the stop
  is received mid-turn, cancels the Engine call, and ends the stream with a
  *"Turn stopped."* notice. As a bonus this keeps the UI responsive to other quick
  requests while a turn runs. +5 unit tests.
- **Reasoning effort no longer breaks turns on models that don't support it.**
  Reasoning effort is a single setting, but support for it is per-model — for
  example `claude-haiku-4.5` supports none. When a higher effort (e.g. *max*) was
  set and such a model was in use, the turn failed with an
  *"invalid_reasoning_effort"* error from Copilot (HTTP 400). Now the effort menu
  in Settings offers only the levels the selected model actually supports (and
  explains when a model supports none), and — as a safety net — the Host Server
  sends the effort to the Engine only when the model in use advertises it, so a
  global preference simply stays inactive on models that cannot honour it instead
  of failing the turn. The model's capabilities are read from the model list the
  app already loads. +5 unit tests.
- **No-project turns no longer read a stray `.memory-bank` (or other files) from
  DeskPilot's launch folder.** With no project selected, the agent's working
  directory was left wherever the Engine happened to be — the folder DeskPilot was
  started from (its own source checkout, which contains a `.memory-bank`), or the
  last project you had open — so a turn could silently read files that belong to an
  unrelated place. An agent that follows a memory-bank / pre-flight convention
  would probe `.memory-bank` and find DeskPilot's own, reporting it as “your”
  context even though no project was defined. Every turn now points the Engine at a
  deterministic working directory: the selected project's folder, or — when no
  project is selected — a neutral `workspace` folder inside DeskPilot's data
  directory. New private helper `Get-DpEngineWorkingDir`; `Invoke-DpTurn` sets the
  location on every turn instead of only when a project is active. +3 unit tests.
- **Every Turn broke against the latest Engine (Task List parameter renamed).**
  ShellPilot made its built-in Task List tool (`manage_todo_list`) on by default
  and renamed the opt-in `-EnableTodoList` switch to an opt-out `-DisableTodoList`.
  DeskPilot still passed `-EnableTodoList` whenever task tracking was on (the
  default), so `Invoke-Shp` rejected the now-unknown parameter and the Turn
  failed. DeskPilot now relies on the Engine's default-on behaviour and passes
  `-DisableTodoList` only when the "Track tasks for multi-step work" setting is
  turned off — preserving the previous behaviour with the new Engine.
- **UI failed to load (no model selectable, Send disabled).** A scrambled edit
  in the previous change shipped a syntax error in the single-page app's module
  bundle, which the browser refuses to execute — so nothing initialised. Repaired
  the bundle and now validate it as an ES module (the way the browser loads it),
  not with a lenient script-mode syntax check.

### Added

- **Regenerate a response.** The last assistant message has a ↻ button that
  re-runs the last prompt and streams a fresh answer (the server truncates to the
  last user message). New `POST /api/conversations/{id}/regenerate`.
- **Edit & resend.** Hover a message you sent to reveal a ✎ button; edit the text
  and resend. The conversation is truncated to that message and re-run with the
  new text, discarding what followed. New `POST /api/conversations/{id}/edit`.
- **Command palette.** Press **Ctrl/Cmd+K** for a searchable palette of actions
  (new conversation, search, settings, customizations, toggle theme, regenerate,
  export) and to jump to a conversation by title. Plus **Ctrl/Cmd+Shift+O** for a
  new conversation and `/` to focus the message box.
- **Reference files.** Mark project-relative files in Settings as always-relevant;
  their paths are added to every turn's system prompt so the agent reads them with
  its File tool when useful — a build-free alternative to a vector database.
- **Spend warning.** Set a per-session USD amount in Settings to get a one-time
  warning when the session's estimated cost crosses it (0 disables it).
- **Find a conversation.** A search box above the conversation list matches your
  conversations by title *and* message text (case-insensitive) and shows a short
  snippet of the hit; press Escape to clear. Backed by a new
  `GET /api/conversations/search` endpoint.
- **Pin & archive conversations.** Each conversation now has a ⋯ menu: pin it to
  the top of the list, archive it (hidden behind a "Show N archived" toggle),
  rename it, or export it. Pinned and archived states persist across restarts.
- **Export a conversation.** From the ⋯ menu, download any conversation as a
  Markdown transcript — title, each message labelled by author, and per-turn
  usage — ready to paste into a memo or report.
- **Voice: dictate and read aloud.** When your browser supports it, a 🎤 Dictate
  button turns speech into a prompt, and every assistant message gains a 🔊
  read-aloud button. Both use the browser's built-in speech APIs — no extra
  dependency, nothing sent anywhere new.
- **Copy a message.** Assistant messages now have a one-click copy button.
- **Artifact preview.** When an answer contains a fenced `html` or `svg` block,
  a **▶ Preview** button renders it live in a sandboxed, script-isolated frame
  (no network, no access to DeskPilot or your files) with a Source toggle.
- **Insert menu in the composer.** A **＋ Insert** button (or typing `/`) inserts
  a Prompt File's body into the composer, filling any `{{variable}}` placeholders
  first; typing `#` references a project file by relative path. Backed by a new
  `GET /api/fs/find` endpoint confined to the selected Project.
- **Drag-and-drop attachments.** Drop files onto the composer to attach them,
  the same as the Attach button.
- **Explain this Customization.** The Customizations editor gains an **Explain**
  button that opens a new chat asking the agent to explain the open file in plain
  language.
- **About you (Preferences).** A durable note in Settings — your role, writing
  style, recurring context — is injected into every turn's system prompt so the
  agent serves you consistently, independent of the selected Agent or Project.
- **Undo a turn's file changes (Git).** When the selected Project is a Git
  repository, each written file in the Activity panel shows a **diff** (rendered
  inline with +/- colouring), and an **↩ Undo file changes** button reverts the
  files a turn wrote to the last commit and deletes files it newly created, after
  an explicit confirm. Backed by new `GET /api/git/diff` and
  `POST /api/git/restore` endpoints, both confined to the Workspace Folder.
- **Atelier health panel.** Settings shows whether each `~/.copilot`
  customization folder resolves, how many agents/skills/instructions/prompts were
  found in each, and flags a missing folder or a broken junction. Backed by a new
  `GET /api/atelier/health` endpoint.
- **Click the logo for home.** The DeskPilot brand in the sidebar is now a
  button: clicking it closes the open chat and returns to the empty "How can I
  help?" home screen (the next message starts a fresh conversation). It is
  blocked with a hint while a turn is streaming. Keyboard-focusable with a
  visible focus ring.
- **DeskPilot brand logo.** The compass-**D** logo replaces the old CSS-drawn
  letter mark and inline-SVG favicon across the app. The exported source art
  shipped on an opaque white background, so the marks are regenerated as
  transparent, theme-aware PNGs: a teal mark on light surfaces and a bright-teal
  (`#2dd4bf`) mark on dark ones, swapped by CSS on the active theme. The mark is
  the favicon (light / dark via `prefers-color-scheme`) and appears in the
  sidebar brand, the empty-state hero, and every assistant-message avatar; the
  sign-in card shows the full *DeskPilot — Navigate with clarity.* lockup (also
  in light and dark variants). The README shows a small logo in the top-right
  corner (theme-aware via `<picture>`), not a full-width banner.
- **Quick light / dark toggle.** A sun/moon button in the top bar flips between
  light and dark instantly, without opening Settings. It reads the *effective*
  theme (resolving `system` against the OS preference), so one click always
  lands on the opposite mode, and it stays in sync with the Settings theme
  dropdown. The icon updates live when the OS theme changes while set to
  `system`.
- **Customizations — manage AI resources.** A new 🧩 Customizations surface
  (opened from the sidebar) lists the agent-shaping Markdown files DeskPilot
  discovers under the configured roots, grouped into four categories — **Agents**
  (`*.agent.md`), **Skills** (`SKILL.md`), **Instructions** (`*.instructions.md`)
  and **Prompt files** (`*.prompt.md`) — each with a count, search, and items
  grouped by scope (`User` for `~/.copilot`, otherwise `Workspace`). Clicking an
  item opens a **line-numbered editor** with an Edit / Preview toggle (Preview
  renders the Markdown) and a Save button (`Ctrl/Cmd+S`); **＋ New** scaffolds a
  fresh Customization in a configured root and opens it. Every read, write, and
  create passes one security gate (`Resolve-DpCustomizationPath`): the path must
  be a descendant of a configured root **and** match the category's file pattern,
  so the surface can never open or write an arbitrary file. Saving an Agent
  refreshes the composer's Agent menu. New backend
  (`Get-DpCustomizationCatalog` / `Root` / `List`, `Resolve-` /
  `Get-` / `Save-DpCustomizationContent`, `New-DpCustomization`) and four routes
  (`GET`/`POST /api/customizations`, `GET`/`PUT /api/customizations/content`).
- **Prompt roots setting.** A new `promptRoots` Setting (defaulting to
  `~/.copilot/prompts`) joins the Skill and Instruction roots, with a matching
  field in the Settings drawer; it backs the Prompt files category above.
- **Mid-Turn dispatch in the composer.** Typing while a Turn is streaming now
  reveals a chevron next to the Stop button that opens a popover with three
  options: **→ Stop and Send** (cancel the running Turn, then send the typed
  prompt as a new one), **+ Add to Queue** (`Alt+Enter`, buffer the prompt and
  fire it the moment the current Turn ends), and **↑ Steer with Message**
  (`Enter`, the default — same as Queue but the prompt sent to the Engine is
  prefixed with a steering preamble so the Model treats it as a course
  correction). Pending entries appear as chips above the textarea with a `×`
  to discard. The user's bubble in the thread carries a small `Steered
  mid-turn` or `Sent from queue` badge after the dispatch fires. Dispatch is
  purely client-side on top of the existing `/messages` and `/stop`
  endpoints; the wire contract is unchanged.
- **CopilotAtelier reference.** README, the project brief and the vision spec
  now point at the CopilotAtelier sibling repo as the canonical Atelier
  exemplar that DeskPilot's `~/.copilot/*` discovery is designed to consume.
- **Logo brief for Microsoft 365 Copilot.** New `docs/logo-prompt-m365-copilot.md`
  is a copy-paste prompt to feed into M365 Copilot / Designer. It pins the
  deep-teal / petrol palette, the 16 px and 20 × 20 px sizing constraints, and
  asks for a logo system that ShellPilot and CopilotAtelier can slot into.

- **In-Turn Task List.** Each Turn now streams a live checklist of sub-tasks the
  agent plans and ticks off as it works, with at most one task `in-progress` at
  a time. The list shows in a compact panel on the assistant Message (○
  not-started, ◐ in-progress, ✓ completed) with a `Tasks — completed/total`
  header, persists alongside the Message, and replays on history reload. A new
  **Task tracking** Setting (on by default) toggles the whole feature; turning
  it off both stops the panel from rendering and stops offering the
  `manage_todo_list` tool to the model. New `tasks` SSE event sends the full
  list on every update (idempotent replace, not a delta); the assistant
  Message gains a `tasks` field carrying the authoritative final list.
- **View a file from the explorer.** Clicking a file in the project file explorer
  opens a viewer modal: Markdown files render formatted (with a **Rendered / Raw**
  toggle), other text files show as plain text, and the size and any preview
  truncation are noted. Files that aren't text say so instead of dumping bytes.
  Backed by `GET /api/fs/file`, which returns a file's UTF-8 text confined to the
  selected Project folder (a path escaping the Project is refused), with a 1 MiB
  preview cap and a NUL-byte binary check.
- **Back up and restore settings.** Settings → **Back up & restore** exports all
  your settings (projects, permissions, agent, tool roots, model preferences) to
  a timestamped JSON file, and restores them from one. Restore is a full replace
  (settings absent from the backup return to defaults). Backed by
  `GET /api/settings/export` and `POST /api/settings/import`.
- **Collapsible project file explorer.** A **☰ Files** toggle in the top bar opens
  a right-hand panel showing the selected Project's folders and files, with
  lazy-expanding directories and file sizes. When no Project is selected the
  panel is collapsed and the toggle is disabled (not expandable). It refreshes
  after each Turn so files the agent creates show up. Backed by
  `GET /api/fs/tree`, which lists one directory level confined to the Project
  folder (a path escaping the Project is refused).

- **Agent picker — choose a persona.** A composer **🤖 Agent** dropdown lists the
  `*.agent.md` personas found under an Agents folder (defaulting to
  `~/.copilot/agents`); the selected Agent's Markdown body becomes the Turn's
  system prompt (composed ahead of the Project/workspace note). "No agent" is the
  default. Backed by `GET /api/agents`; the Agents folder is editable in Settings.
  Skill and Instruction roots now also default to `~/.copilot/skills` and
  `~/.copilot/instructions` when present (FR-M3, FR-M5).

- **Projects — registered, named working folders.** Workspace folders are now
  managed as **Projects** (`{ id, name, path }`). A composer dropdown — a custom
  menu styled to match the app's other popovers, not a native `<select>` —
  switches between registered Projects and offers **New project…**, and the
  settings drawer lists Projects with select/remove plus an add row. The
  selected Project is the working directory for new Turns and persists across
  sessions as the default; the Turn's system prompt now names the active Project
  (FR-M2, FR-M2a). The legacy single `workspaceFolder` is kept as a derived,
  in-sync field so a direct write is migrated into a registered Project, and all
  Turn/Upload code is unchanged. `PUT /api/settings` accepts `projects` and
  `selectedProjectId` (an unknown selection returns `400`). No two Projects may
  share a name or folder path (trailing separators ignored) — a duplicate is
  rejected with `400`, and the UI blocks it before sending.
- **Folder picker for registering a Project.** Registering a Project now opens a
  styled folder-browser modal — drive switcher, breadcrumb path (editable for
  paste), Up/Home, a scrollable sub-folder list, and a **New folder** action —
  instead of a bare text prompt. Backed by `GET /api/fs/list` (lists sub-folders,
  hidden/system skipped, falls back to home) and `POST /api/fs/mkdir` (creates a
  single segment, rejecting separators and `..`). The settings-drawer add row is
  now a single **Add project…** button that opens the same picker.

- **Settings persist across sessions.** Permissions, the Workspace Folder, the
  default model, and skill roots are written to `settings.json` in the per-user
  data directory whenever they change (via `PUT /api/settings`) and loaded on
  startup, so a configured permission set is remembered the next time DeskPilot
  launches (FR-S1).
- **File uploads — attach files to the chat.** A new **📎 Attach** button in the
  composer uploads one or more files to `POST /api/uploads`; the Host Server saves
  them into the Workspace Folder (collision-safe naming, 25 MiB per-file cap) and
  the next message tells the agent which files were attached so it can read them
  with its file tool. No engine attachment support is required (FR-C9).
- `POST /api/uploads` (`multipart/form-data`) returning
  `{ files: [{ name, savedAs, path, bytes, contentType }] }`; 400 when no
  Workspace Folder is configured, 413 when a part exceeds 25 MiB.
- **Conversations persist across sessions.** The Conversation store is written to
  `conversations.json` in a per-user data directory after every change and loaded
  on startup, so chats survive a Host Server restart. Deleting a Conversation
  removes it from disk as well as memory (FR-C7, FR-C8).
- **Lifetime credit counter.** Alongside the per-session Usage counter (which
  resets each launch), DeskPilot now keeps a persisted **lifetime** counter
  (credits, cost, tokens, turns, and a `since` date) in `lifetime-usage.json`
  that accumulates across sessions and is never reset automatically. The sidebar
  shows session credits; a new usage popover shows both counters with a manual
  **Reset all-time counter** button (FR-U2, FR-U3, FR-U4).
- `POST /api/usage/reset` (`scope: lifetime | session`) and a reshaped
  `GET /api/usage` returning `{ session, lifetime, byModel }`.
- `Start-DeskPilot -DataDir` to override the per-user data directory.
- **Live end-to-end test harness** (`tests/live/Invoke-DeskPilotLiveTest.ps1`)
  that drives real streaming Turns against GitHub Copilot through the SSE message
  endpoint and verifies the simple-turn, multi-turn-history, tool-using,
  workspace-write, restart-persistence, lifetime-reset, settings-persistence, and
  file-upload paths. Kept out of the Pester unit suite because it consumes Copilot
  credits; uses the cheapest discovered Model.
- Regression unit tests for `ConvertFrom-DpEngineResult` (empty activity),
  conversation/lifetime/settings persistence round-trips, the multipart
  form-data parser, the unique-filename helper, and the usage payload.

### Changed

- **New visual identity — deep teal / petrol, no longer Claude-style.** Replaced
  the warm terracotta accent and the serif reading font with a cool, crisp light
  theme and a dark blue-green dark theme, both keyed off a vivid teal accent.
  Added an `--on-accent` design token so the bright dark-mode accent carries
  legible dark text and glyphs; updated the favicon to match. The
  system/light/dark theme switch is unchanged.
- **Logo brief reworked for 5 proposals + both homes.**
  `docs/logo-prompt-m365-copilot.md` (the Microsoft 365 Copilot / Designer
  brief) now asks for **5** distinct proposals (was 4), foregrounds the
  **Agentic Operating Model** — DeskPilot as the *friendly front door to the
  AOM* — and the literal **ShellPilot** *cockpit-vs-engine* family
  relationship, and adds a **Where the logo will live** section that pins the
  two homes: the **GitHub repository** (README hero + 1280 × 640 social-preview
  card, light and dark variants) and the **DeskPilot entry page** (the
  20 × 20 px in-app brand swatch, the 16 × 16 px favicon, and a start-screen
  splash lockup). Deliverables and concept directions were expanded to match.- **Themed scrollbars.** Replaced the raw OS scrollbar with a slim, rounded
  scrollbar styled to the deep-teal / petrol palette: a pill thumb in a muted
  petrol tone that brightens on hover, on a transparent track. Theme-aware via
  new `--scrollbar-track` / `--scrollbar-thumb` / `--scrollbar-thumb-hover`
  tokens in the light and both dark blocks; applied through WebKit
  (`::-webkit-scrollbar*`) and Firefox (`scrollbar-width` / `scrollbar-color`).
### Fixed

- **The file explorer now refreshes when you switch projects.** With the explorer
  open, picking a different project from the composer dropdown (or the settings
  drawer) left it showing the previous project's files; it now reloads the tree
  and Git bar for the newly selected project. The explorer tracks the rendered
  project path and only re-fetches when it actually changes.

- **The credits popover now fills in as soon as it opens.** It was revealed
  before its contents were rendered (the populate step was guarded on the popover
  already being visible), so the session/all-time figures and the per-day chart
  only appeared after clicking **7d**/**14d**. The popover is now populated from
  fresh data before it is shown, with the 14-day chart as the default view.
- **Credit totals no longer drift.** The session, lifetime and per-Model counters
  accumulated raw per-Turn credits/cost without rounding, so floating-point error
  produced ugly values like `2.3987000000000003` and `0.6174999999999999`.
  Credits are now rounded to 4 decimals and cost to 6 on every accrual (matching
  the Engine's per-Turn precision), and existing persisted values are healed on
  load.

- **The live (streaming) answer is now clean and formatted.** With "show
  thinking" on, the Engine emits a host-only colour trace — per-iteration banners
  (`=== iteration N (chat) ===`) and tool-call traces (`-> run_command(...)`) —
  that DeskPilot was leaking into the answer because only the DarkGray reasoning
  colour was recognised. The trace (DarkCyan banners, Cyan tool calls, Yellow
  notes) is now routed to the **Thinking** disclosure, so only the real answer
  tokens stream into the message body. The live answer is also rendered as
  Markdown as it streams (throttled to one paint per frame), so it looks like the
  final message instead of raw `##`/`**`/table source. The fix is in DeskPilot's
  stream classifier; the Engine's trace is documented host-only behaviour.
- **File uploads no longer fail with "Missing or invalid session token."** The
  composer's upload `fetch` did not send the `X-DeskPilot-Token` header (it can't
  reuse the JSON `api()` helper, which would mangle the `multipart/form-data`
  body), so the token gate rejected every browser upload with `401`. The header
  is now sent on the upload request (without overriding the multipart
  `Content-Type`, which the browser must set itself).
- **Sign-in is clearer when the engine or token isn't ready.** The connect screen
  now shows engine state (and disables **Connect** with guidance when ShellPilot
  isn't loaded), short-circuits to success if a token already exists (for example
  after running `Initialize-Shp` in a terminal) instead of starting a second
  device-code flow, and offers an **"I've signed in elsewhere"** re-check so an
  external sign-in is picked up without restarting DeskPilot.

- **The all-time credit counter is now visible at a glance.** The sidebar credit
  chip previously showed only the per-session counter, which resets to zero each
  launch — so the persisted all-time total looked stuck at 0 unless you opened
  the usage popover. The chip now shows both as `session / all-time cr` (the
  all-time figure emphasised), so cumulative spend is always visible and visibly
  increments across sessions. The accrual itself was already correct (verified:
  a real Turn moved the persisted lifetime counter from 1.6602 to 1.8233).
- **Ctrl+C now stops the Host Server promptly.** The accept loop blocked on the
  synchronous `TcpListener.AcceptTcpClient()`, and PowerShell can only act on a
  Ctrl+C (pipeline stop) between statements — never while parked inside a
  blocking .NET call — so the server ignored Ctrl+C until a connection happened
  to arrive. The loop now polls the non-blocking `Pending()` and yields through
  the `Start-Sleep` cmdlet (a cancellation checkpoint) when idle, so Ctrl+C is
  observed within one poll (~50 ms) and unwinds through the listener's cleanup.
  A closing "DeskPilot stopped." line confirms shutdown.
- **Persisted timestamps survive a load/save cycle.** `ConvertFrom-Json` coerces
  ISO-8601 strings into `[DateTime]`, which would reformat dates in the local
  culture on reload; a new `ConvertTo-DpIsoString` normalises them back to
  ISO-8601 UTC.
- **The Workspace Folder is now actually used by the agent.** Previously a
  configured Workspace Folder was ignored: the model was never told about it (so
  it chose its own location for new files), and the Engine's working directory
  was only changed when the folder already existed, so a not-yet-created folder
  left the agent writing into the server's launch directory. Now each Turn
  injects a system prompt naming the working directory, and DeskPilot creates the
  Workspace Folder if needed and sets both the runspace location and the process
  current directory before the Turn runs. Verified live: the agent writes new
  files into the configured (auto-created) folder without the prompt naming the
  path.
- **Tool-less Turns no longer fail under `Set-StrictMode -Version Latest`.**
  `ConvertFrom-DpEngineResult` built its Activity arrays with
  `@(...) | ForEach-Object { ... }`, where the `@()` wrapped only the source; an
  empty source collapsed the pipeline to `$null`, and the subsequent `.Count`
  access threw "The property 'Count' cannot be found on this object", surfacing
  as a Turn error. Each pipeline is now wrapped in `@()` so empty activity always
  yields an empty array. Verified live against the model.

### Added (bootstrap)

- **Memory Bank** establishing project context: brief, product context, tech
  context, system patterns, an Ubiquitous-Language glossary, active context, and
  progress.
- **Specifications** under `specs/`: overview, requirements (MoSCoW),
  architecture, REST + SSE API contract, UI design, security model, and roadmap.
- **Host Server** (`src/DeskPilot`), a PowerShell 7 HTTP + Server-Sent-Events
  bridge that fronts the ShellPilot engine:
  - Loopback `TcpListener` with a hand-rolled HTTP/1.1 request parser and
    response writer (no admin rights or URL ACL required).
  - Per-launch session-token gate on the `/api` surface; static SPA serving with
    a path-traversal guard and `index.html` fallback.
  - REST endpoints for health, auth status, models, settings, usage, and
    conversation CRUD; SSE endpoints for device-code sign-in and message turns.
  - One long-lived Engine runspace; turns run `Invoke-Shp` and stream answer
    (and optional reasoning) deltas captured from the Information stream.
  - Conversation isolation via the engine's `-History`; permissions mapped 1:1
    to the engine's `-Disable*` switches; per-turn Activity and Usage mapping;
    cumulative usage accumulation.
- **Web UI** (`web/`), a build-free, single-page app: sidebar of
  conversations, streaming message thread with Markdown rendering, composer,
  model picker, permissions popover, workspace-folder chip, settings drawer,
  device-code auth screen, and per-message Activity/Usage panels. Light and dark
  themes; XSS-safe in-house Markdown renderer.
- **Launcher**: `Start-DeskPilot.ps1` and the Windows `DeskPilot.cmd`
  double-click entry point.
- **Tests**: a Pester 5 suite (28 tests) covering settings merge/validation,
  route matching, SSE framing, id and conversation creation, turn-parameter
  assembly, engine-result mapping, and the static-content traversal guard.
- **Docs**: README and this changelog.

[Unreleased]: https://github.com/raandree/AgenticOperatingModel/compare/main...HEAD
