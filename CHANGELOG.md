# Changelog

All notable changes to DeskPilot are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Pick the model from your phone.** Intercom could switch the conversation, the
  agent and the project, but not the model, so choosing one still meant walking
  back to the machine. `/models` lists the models your account is offered, marks
  the one your next instruction would run on and gives you a button per model;
  `/model 2` picks one and `/model default` goes back to the standard one.
  `/status` now names the model too. A switch applies to your next instruction —
  it never disturbs a job already running — and it changes both the default and
  the conversation you are in, so the model you were told about is the model that
  actually runs. While a job is running and the list has never been loaded,
  `/models` says so and asks you to try again afterwards rather than freezing
  DeskPilot to go and fetch it.
- **Switch agent and project from your phone.** Intercom could switch
  conversations but not the two things that decide *how* and *where* the agent
  works. `/agents` lists the agents you have, marks the one in use and gives you
  a button per agent; `/agent 2` picks one and `/agent none` goes back to the
  default. `/projects` does the same for your projects and says on every line
  which ones you are allowed to work in from your phone, so you learn that before
  you send an instruction rather than from a refusal. `/project new C:\Git\Notes`
  registers a folder as a project — creating that last folder if it does not
  exist yet — and `/status` now names the agent in use. A project added from your
  phone is deliberately **not** remote-controllable until you switch that on at
  the machine.
- **Dictate and read aloud in German.** Voice used to follow whatever language
  your browser was set to, so speaking German into an English Windows produced
  transcription nonsense and had your answers read back in an English accent.
  **Settings → General → Voice language** now lets you choose: German (Germany,
  Austria, Switzerland), English (US, UK), or Auto to keep following the browser.
  A **Voice** setting sits underneath it, listing every voice installed for that
  language so you can pick the one you like — or leave it on Automatic, which
  picks the best one for you.
- **Asking for choices now gets you choices.** "Give me a list to choose from"
  or "what are my options" used to be answered with a written list you could only
  read. The agent now offers those as a real question you can answer — a
  questionnaire in the window, tappable buttons on your phone — so picking one
  actually carries on the conversation. It still will not turn a simple request
  into a wizard: it never asks to confirm something it can just do.
- **Tap to answer, instead of typing.** When the agent asks a question with a
  list of choices, Telegram now shows a button for each one — tap it and that is
  your answer. `/chats` gives you a button per conversation too, so switching no
  longer means reading a list and typing a number. You can still reply in writing
  whenever you prefer, and questions that let you pick several answers at once
  still ask for a written reply, because one tap cannot say "these two".
- **Rewind a conversation to before a prompt.** Every message you send now
  carries a **Restore Checkpoint** marker above it. Clicking it takes you back to
  the moment just before you hit send: the message and everything after it leave
  the conversation, your prompt goes back into the box so you can reword it, and
  any file DeskPilot changed since is put back the way it was. Files you edited
  yourself are left alone, and DeskPilot asks before it discards anything. The
  marker appears as soon as the turn finishes — you do not have to reopen the
  conversation to see it.
- **Undo from your phone.** Send `/undo` to Intercom and DeskPilot tells you
  exactly what it would throw away — how many messages, how many files — then
  waits. `/undo confirm` takes you back to just before your last instruction,
  puts back the files it changed, and sends your prompt back so you can reword it
  and try again. It refuses while a job is running, so send `/stop` first.

### Changed

- **The Thinking panel now tells you the time.** When a job takes minutes, the
  panel gave you no way to tell whether the wait was the model thinking, a tool
  running, or DeskPilot stuck. Every divider and every tool call now starts with
  the clock, so the pause between two steps is there to read: `14:07:09` on one
  divider and `14:07:31` on the next is twenty-two seconds you can now account
  for. The time is the moment the agent actually did it, not the moment your
  browser drew it, so a busy screen cannot flatter the numbers.

- **The model's thinking is now readable.** Every time the agent used a tool, the
  Thinking panel showed the raw instruction it sent — one endless line in which
  each line break of a file it was writing appeared as a literal `\n` and every
  Windows path came out doubled, like `C:\\Users\\you`. It now reads as what it
  is: the tool's name, then each of its inputs on its own line, with the text laid
  out the way it will actually be written. The `=== iteration 4 (chat) ===`
  markers became plain dividers, and the panel keeps its own height and scrolls
  by itself, so a long think no longer pushes the answer off the screen.

- **You can watch the agent think while it writes.** The Thinking panel sits
  above the answer, so as soon as the answer filled a screen the panel scrolled
  out of sight and all that was left was the spinner — which looks exactly the
  same whether the agent is busy or stuck. The newest line of the thinking now
  runs beside that spinner just above the box you type in, where a long answer
  cannot push it away, and clicking it takes you back to the full panel. The
  conversation also follows new output only while you are already at the bottom,
  so scrolling up to read along is no longer undone by the next word.

- **New conversations start on Claude Opus 5.** DeskPilot used to inherit
  whatever model the engine happened to name as its default, which trails the
  newest one by months. It now asks for Opus 5 whenever your account is offered
  it, and falls back to the engine's own choice when it is not — so nothing
  breaks if it is unavailable to you. Picking a model yourself, in Settings or on
  a single conversation, still wins.

### Fixed

- **Stopping a job no longer throws away its thinking.** With **Show the model's
  thinking** on, the pane filled up while the job ran — and pressing **Stop**
  blanked it on the next reload, because the trace was only ever held in the
  browser and the stopped message was saved with nothing in it. The thinking you
  watched is now saved with the message, so a stopped job still explains itself
  afterwards.
- **Intercom now tells you where the phone-control switch actually is.** When a
  project was not cleared for phone control, Intercom said "Remote control is
  switched off … turn it on under Settings > Intercom" — a tab that holds no such
  switch, and which the message was printed on while it plainly read
  "On — connected". It now names the checkbox you are looking for and the tab
  that carries it: tick **allow phone control** on the project under
  **Settings → Projects**. The same correction applies when you switch to a
  project from your phone, when you add one with `/project new`, and in the
  getting-started guide.
- **Read aloud no longer sounds like a robot from ten years ago.** It used the
  first voice the system happened to list for the language, which on Windows is
  the oldest one installed — the flat, clipped "Desktop" set. It now prefers a
  modern voice when one is available (the ones labelled *Natural* or *Online* in
  Microsoft Edge, or the Google voices in Chrome), which is a different era of
  sound: real intonation, real emphasis, real pauses. If you would rather choose
  yourself, every installed voice for your language is listed in Settings.
- **Years are read as years.** "in 1945" was read out as "one thousand nine
  hundred forty-five". It is now spoken the way a person would say it —
  "nineteen forty-five", or "neunzehnhundertfünfundvierzig" in German. Only a
  number that actually follows a date word is treated this way, so a port number
  or a count of files is still read exactly as written.
- **Read aloud no longer reads the punctuation.** An answer was spoken exactly as
  it was written, so a heading came out as "hash hash Setup", bold text as "star
  star", a table as a run of "vertical bar", and a bullet list as a string of
  "dash". Formatting is now removed before anything is spoken: headings, list
  items and table rows are read as ordinary sentences, a link is read by its
  label rather than its address, and a code block is announced instead of being
  spelled out character by character.
- **The model's thinking is now actually shown.** With **Show the model's
  thinking** turned on, the Thinking box arrived collapsed, so you still had to
  find and click it on every answer — and because it only appeared after the view
  had already scrolled, it unfolded below the bottom of the window, which made a
  long think look like a stalled turn. The box now opens by itself when the
  setting is on, and the view follows it as it is written.
- **A Windows-written Markdown file no longer freezes the window.** Opening a
  `.md` file saved with Windows line endings — which is most files DeskPilot did
  not write itself — left the preview stuck on "Loading…" and locked up the whole
  window until the tab was closed. The first heading was the trigger: the
  renderer did not recognise it, then had no way to move past the line, and went
  round forever. Line endings are now normalised before anything is rendered, and
  the renderer can no longer get stuck on a line it does not understand.
- **Undoing a file now clears it from the review list.** The diff viewer kept the
  file list it opened with, so after you confirmed an undo the file was still
  listed, still showed its old diff, and still offered a second **Undo this
  file** for a change that was already gone. The viewer now re-reads the change
  set after every Keep or Undo: a file that no longer differs drops out, the
  selection moves to the next file, and the viewer closes when nothing is left
  to review. A file put back through Git also stops being reported as an
  unreviewed DeskPilot change.
- **The window keeps up with your phone.** Archiving, unarchiving, deleting or
  starting a conversation from Telegram now updates the DeskPilot sidebar within
  a few seconds, instead of leaving a deleted conversation listed and
  unclickable. Clicking a conversation that has since gone says so and refreshes
  the list, rather than doing nothing at all.
- **An archived conversation no longer accepts new work.** Sending, regenerating
  or editing a turn in an archived conversation — from the window or from your
  phone — is refused with a message telling you to unarchive it first. Archiving
  is you saying you are done with it.
- **Deleting the conversation your phone was working in is now an error.**
  Intercom used to fall through to "the most recent one" and quietly do the work
  somewhere you never chose. It now refuses and asks you to pick one with
  `/chats` or start one with `/new`.
- **Deleting a conversation asks first.** The ✕ button beside a conversation now
  **archives** it (reversible); deleting moved into the ⋯ menu — also reachable
  by right-clicking the row — and always confirms.
- **Linking your phone to Intercom no longer requires hunting for a chat id.**
  Intercom ignores every chat until you confirm one, which meant your bot stayed
  silent — even to `/start` — and there was no way to discover the number from
  it. **Settings → Intercom → Link my phone** now listens for five minutes,
  shows you the message it saw, and links the chat when you click **This is me**.
  Nothing is ever linked automatically, and nothing you send during that window
  is executed.
- **A model with no published rate no longer reads as free.** The engine prices a
  turn from a table keyed by exact model id; a model newer than that table (for
  example `claude-opus-5`) comes back with *no* price, and DeskPilot was showing
  that as a confident `$0.0000 · 0 credits` — over a million tokens could look
  free. Such a turn now says **cost unknown — no published rate for this model**,
  session and all-time totals show a `≥` prefix and count how many turns could
  not be priced, and the per-model list says **no rate** instead of `0 cr`. The
  fix for the *number* is a rate for the model in the engine's price table; this
  fix is DeskPilot no longer misreporting its absence.

### Added

- **Copy your own messages with one click.** Hovering a message you sent now
  shows a ⧉ button beside the edit one, the same as on DeskPilot's replies — no
  more selecting a prompt by hand to reuse it. Both also fall back to an older
  copy method if the browser refuses clipboard access.
- **Send files from your phone.** Attach a document, photo, voice note or video
  in Telegram — with or without a caption — and DeskPilot saves it into your
  project folder and puts the agent to work on it; photos also go to the model's
  vision input. Previously an attachment was ignored without so much as a reply.
  Files up to 20 MB (Telegram's own limit), and only from a project with **allow
  phone control** ticked.
- **Choose how a message is sent.** **Settings → General → Send a message with**
  offers **Ctrl+Enter** (the new default, with Enter making a new line) or
  **Enter** (with Shift+Enter making a new line). Ctrl+Enter by default so a
  stray Enter mid-thought cannot fire a half-written instruction at an agent that
  can change files and run commands.
- **Tidy up conversations from your phone.** `/archive 2` hides one from the
  list, `/unarchive 2` brings it back, and `/chats all` lists the archived ones
  so you can see their numbers; `/delete 2` removes one for good and asks you to
  confirm first, offering `/archive` as the reversible alternative.
- **Watch a phone-driven job from the machine.** While a job you sent from
  Telegram is running, the DeskPilot window marks that conversation and shows the
  answer being written — including the model's thinking when that is switched on.
  No page refresh.
- **Telegram messages are formatted properly.** The agent writes Markdown and
  Telegram renders none of it, so answers used to arrive as a wall of `##`, `**`
  and pipe-delimited tables. Headings, bold, bullets, links, code and tables now
  come through readable, and a message Telegram cannot render is resent as plain
  text rather than lost. Telegram has no tables at all, so a narrow one is shown
  as an aligned block and a wide one as one labelled record per row — long tables
  are trimmed with a note pointing you back to DeskPilot for the rest.
- **Switch conversations from your phone.** Intercom gains `/chats` to list your
  conversations (newest first, marking the one you are in), `/chat 2` to switch
  to one, and `/new` to start a fresh one. Asking the *agent* to switch chats
  never worked and never could — which conversation is open is DeskPilot's state,
  not something the agent can see or change. Listing and switching run nothing,
  so they work even when no project is open; `/new <text>` still needs a project
  with **allow phone control** ticked, because that runs work.
- **Reach DeskPilot from your phone (Intercom).** When the agent needs an
  answer, finishes, fails, or goes quiet, DeskPilot messages you on Telegram —
  and you can reply to answer it, send a new instruction, `/stop` the job,
  `/steer` it somewhere else, or `/new` a fresh conversation, without a remote
  desktop session. It is **off by default** and stays off for every project until
  you tick **allow phone control** on that project, so nothing can be driven
  remotely by accident. Exactly one Telegram chat is allowed; anything else is
  counted and thrown away without being read as an instruction. The bot token is
  encrypted for your Windows account in its own file, so a settings backup can
  never carry it. DeskPilot also keeps one silently-updating status message on
  your phone that always states the time of its next check-in — if that time has
  passed, DeskPilot has stopped. Set it up under **Settings → Intercom**; the
  [getting-started guide](docs/intercom-getting-started.md) walks through it.
- **The files panel is resizable.** Drag its left edge to make it as wide as you
  need (up to 60 % of the window), double-click the edge to snap back to the
  default, or focus it and use `←`/`→` — `Shift` for bigger steps, `Home` to
  reset. The width is remembered on this machine.
- **Save all your changes at once, without knowing Git.** The Changes panel gains
  a **Save all…** button (also in the Branch Wizard when you have unsaved work,
  and in the command palette) that opens one dialog: it lists every uncommitted
  file with its added and removed line counts, prefills an editable one-line
  description, and records the lot as a single entry in the project's history.
  No staging, no `git add`, no terminal — and nothing is sent anywhere until you
  choose **Send to server**. Saving a file also stops DeskPilot reporting it as
  an unreviewed change, because a file you saved is a file you reviewed.
- **Let DeskPilot write the description.** A ✨ button beside the box reads your
  changes and suggests a one-line description, the way GitHub Copilot's commit
  box does. It only ever fills the box — you read the words and decide — and it
  runs on your click, never on its own.
- **DeskPilot now remembers what it changed until you decide.** Before every turn
  it records how your files looked, so the edits the agent makes stay listed as
  *not reviewed yet* — across a reload, a restart, and switching conversations —
  until you **Keep** them (accept, without committing) or **Undo** them. Undo puts
  a file back the way it was *before the agent touched it*, so your own earlier
  edits survive, and a file the agent created is removed. This is a layer above
  Git: "what did the agent change?" and "what is uncommitted?" are different
  questions and now have different answers.
- **A Changes card under every new answer, with Keep and Undo.** When the agent
  edits files in a Git project, the answer now carries a
  `N files changed  +A  −D` summary and one row per file with its status and its
  own added/deleted line counts, measured against the pre-turn snapshot. The card
  disappears once those files are reviewed.
- **Changed files are visible in the file panel, not buried in Activity.** A
  **Changes** panel sits directly under the Git bar with two sections — what
  DeskPilot changed and you have not reviewed (with **Keep all** / **Undo all**),
  and what is merely uncommitted — and the file tree itself is colour-coded the
  way an IDE explorer is: a changed file's name takes its status colour (amber
  modified, green new, red deleted or conflicting) and carries a one-letter
  status, a folder containing changes is tinted and shows how many changed files
  are inside, and an unreviewed DeskPilot change carries an accent edge.
- **A diff viewer.** Clicking a changed file opens a unified diff with both old
  and new line numbers, colour-coded additions and removals, and a file list to
  step through the whole change set (`↑`/`↓`). A pending DeskPilot change is shown
  against the pre-turn snapshot, so you see what the agent did rather than
  everything since your last commit. A brand-new file is shown as all additions;
  a binary file says so instead of showing bytes.
- **A Branch Wizard for people who do not know Git.** One place to see where you
  are, create a branch (with the name validated in plain language before Git
  sees it), switch, delete (never the default branch; unmerged work needs an
  explicit "delete anyway"; the remote delete is a separate opt-in), merge (hands
  off to the existing Merge Wizard), and sync with the server — *get*, *send*, or
  both, including publishing a branch that has never been sent. Uncommitted work
  can be set aside and restored around a sync.
- **A generated prompt for merge conflicts.** When the same lines were changed in
  two places outside the Merge Wizard, DeskPilot writes the prompt that asks the
  agent to resolve it, shows it for review and editing, and sends it only when
  you choose to. Copy and Abort-the-merge are offered alongside.
- **Ask you now opens a Questionnaire wizard for related questions.** The Model
  can bundle up to ten questions into one in-thread flow with numbered choices,
  radio-style single selection, checkmarked multi-selection, conditional custom
  answers, previous/next navigation, progress, collapse, and close-to-Stop.
  Text-only questions show only a free-text field; plain Engine questions remain
  a one-step fallback. Answers return to the same Turn as one correlated JSON
  payload, and the completed Activity shows the Questionnaire title instead of
  protocol JSON.

### Changed

- **Git can no longer hang DeskPilot.** Every Git call now reads its output
  asynchronously and runs with terminal prompting disabled, and networked calls
  (fetch, push, remote delete) carry a timeout. Previously a stalled remote or a
  credential prompt could freeze the single-threaded Host Server, and with it the
  whole UI.
- The per-turn file diff moved from an inline block in the Activity panel into
  the new diff viewer, and the Activity panel's "Undo file changes" button moved
  into the Changes card as **Undo**.

### Fixed

- **The Project chip now shows the selected folder's leaf name.** The chip
  sizes itself to shorter folder names, caps long names with an ellipsis, and
  exposes the full leaf name on hover instead of showing a stale Project name
  or the folder's root.
- **Stop now reacts immediately and preserves the interrupted Turn's Usage.**
  Clicking Stop freezes further streamed text at once, disables the button as
  **Stopping…**, and cancels the Engine pipeline asynchronously so the Host
  Server can keep processing requests while it unwinds. The resulting stopped
  Message is persisted with its credits and cost. Exact Engine Usage is used
  when available; hard-stopped streams that never receive the provider's final
  token frame show a clearly labelled input-only estimate instead of zero.
- **Ask you now pauses for an in-thread answer instead of reporting that no
  interactive console is available.** DeskPilot captures ShellPilot's structured
  `ask_user` Tool event, renders a correlated answer card, feeds the response to
  the waiting Engine Runspace, and resumes the same Turn. Repeated questions can
  form a multi-round interview, stale answers are rejected, and Stop cancels a
  pending question. Adds a `POST /api/conversations/{id}/question` route and
  focused Host Server, Engine-contract, and web-asset tests.
- **The GitHub sign-in screen no longer hides the device code behind its own
  progress output.** The Engine writes one line per poll while it waits for you
  to authorise, and the sign-in panel appended every one of them, so the
  verification link and the user code scrolled out of the small box within
  seconds and the screen looked stuck. Sign-in progress is now a fixed panel:
  the link and the code stay pinned with a **Copy code** button, and the poll
  heartbeat only updates a single status line. The code step also spells out
  that GitHub's password and two-factor prompts are the normal sign-in and that
  the device code belongs only in the **Device activation** box — pasting it
  into the two-factor field is rejected by GitHub. A sign-in that ends without a
  token now says the code may have expired instead of only "Try again". Adds a
  small `auth.js` browser module and one focused unit test.

## [0.3.0] - 2026-07-23

### Added

- **Paste files and images into the prompt box as Attachments.** Clipboard files
  now use the same upload and pending-chip flow as the Attach button and
  drag-and-drop, while text-only clipboard content continues to paste normally.
  Uploaded images from any of those three entry points are also sent through the
  Engine's native `-Image` input for Vision-capable Models. The Message route
  accepts only absolute, existing `image/*` files recorded by the current Host
  Server's upload route before forwarding them (`400 invalid_attachment` for an
  unregistered, relative, missing, or non-image path). That per-launch registry
  also keeps a pending Attachment valid when the selected Project changes. Adds
  a small `attachments.js` browser module and twelve focused unit tests.
- **Automatic update checks with a consent-gated in-app update.** DeskPilot now
  polls the PowerShell Gallery for a newer release in the background (every 5
  minutes by default, configurable in **Settings → Engine & data → Updates**, plus
  a manual **Check for updates** button) and, when one is found, shows a dismissible
  banner in the UI. Clicking **Update now** installs the newest DeskPilot **and**
  ShellPilot into the CurrentUser scope, then **force-reloads ShellPilot live in the
  Engine Runspace** so the Engine update takes effect immediately; DeskPilot's own
  host code can't hot-swap in-process, so a one-click **Restart DeskPilot** relaunch
  applies it (a fresh process imports the updated modules, keeping your
  Conversations). Full releases are offered by default; an
  opt-in **Include preview releases** setting also considers previews, and updating
  DeskPilot to a preview accepts a preview ShellPilot too — otherwise both are
  pinned to stable. The check is fail-silent and never blocks serving (it runs in a
  background job), and the notice is web-UI only (no console output). New
  `GET /api/update`, `POST /api/update/check`, `POST /api/update/install`, and
  `POST /api/update/restart` routes; new `updateCheckIntervalMinutes` and
  `updateIncludePrereleases` Settings; new `Get-DpUpdateStatus`,
  `Invoke-DpSelfUpdate`, `Get-DpUpdatePayload`, `Update-DpUpdateCheckState`,
  `Update-DpEngineModule` (live Engine reload) and `Restart-DpHost` (relaunch)
  helpers (replacing the launch-only, console-only `Get-DpUpdateNotice`); +20 unit
  tests.
- **DeskPilot version shown in the sidebar corner.** The running version (from
  `GET /api/health`) now appears as a muted `DeskPilot vX.Y.Z` line in the
  bottom-left of the sidebar, so the installed build is always visible at a glance
  (and easy to quote alongside the update banner).
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

- **Update check no longer reports "up to date" when a newer preview exists.** With
  **Include preview releases** enabled, a preview install (for example
  `0.2.0-preview0004`) was never offered a newer preview (for example
  `0.2.0-preview0005`). DeskPilot read the running version from the module's
  `[System.Version]`, which cannot carry a prerelease label, so a preview build
  reported itself as the matching **stable** release (`0.2.0`); because a stable
  release outranks its own previews, no `0.2.0-preview*` was ever seen as newer.
  DeskPilot now recombines the base version with its `PrivateData.PSData.Prerelease`
  label (new `Get-DpModuleVersionString` helper) so the Update check — and the
  sidebar version line, both fed from the running version — reflect the true running
  preview, and the post-install result reports the full preview version. +12 unit
  tests.

- **Context Window gauge no longer over-reports (and auto-compaction no longer
  fires on almost every Turn).** The Session Info gauge could show impossible
  figures such as *9,140,447 / 1,000,000 tokens · 100%* with a nonsensical
  "System + tools" breakdown of several million tokens. The cause: the Engine's
  `promptTokens` is the **sum** of input tokens across every tool-calling
  round-trip in a Turn (correct for cost — each round-trip is billed), but DeskPilot
  read it as the size of a single prompt. A Turn that made nine tool calls therefore
  read as roughly nine times the context window. DeskPilot now divides that sum by
  the Turn's round-trip count (`iterations`, newly surfaced on each Message's usage)
  to recover a single prompt's size — the amount that actually occupies the context
  window (exact for a Turn with no tool calls). Because automatic compaction watches
  the same occupancy, this also stops it from triggering on nearly every Turn.
  Cost, credit, and token totals are unaffected — they still reflect the full billed
  usage.

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