---
schema-version: 1
status: accepted
owner: shared
last-verified: 2026-08-05
source: repository evidence
---

# System Patterns — DeskPilot

## Core decisions

1. **The Engine is sacrosanct.** DeskPilot never re-implements Copilot calls,
   tools, or auth. It orchestrates `Invoke-Shp` and friends. Anything the Engine
   gains, DeskPilot can surface.
2. **One long-lived Engine Runspace.** The Engine is imported once at startup
   and authenticated once. Every Turn runs `Invoke-Shp` on this runspace via a
   fresh `[PowerShell]` instance, so module-scoped state (auth, model) persists
   while per-Turn Streams stay isolated.
3. **Conversation isolation via `-History`.** Each Conversation owns a history
   array. A Turn replays that array with `-History`, then appends the returned
   `.History`. The Engine's own running chat is never used, preventing bleed
   between Conversations.
4. **Streaming through the Information stream.** With Engine streaming on, answer
   tokens arrive as `Write-Host` calls captured on the `[PowerShell]` instance's
   `Streams.Information.DataAdded`. The handler enqueues each delta to a
   thread-safe queue; the SSE loop drains it to the browser. The final Message
   text is taken from `.Content` (clean, ANSI-free).
5. **Single-threaded accept loop.** For one local user, the Host Server accepts
   on the main thread and handles each request inline. Only the Engine call runs
   off-thread (its own `[PowerShell]`/runspace) so the SSE loop can write deltas
   while it runs. Multi-client concurrency is explicitly out of scope for v1.
6. **Static, build-free frontend.** The SPA is plain files the Host Server
   serves. No bundler, no npm — nothing for an end user to install.

## Patterns to keep

- **Boundary validation only.** Validate inputs where the browser meets the Host
  Server (route params, JSON bodies) and where the Host Server meets the Engine
  (parameter assembly). Do not sprinkle defensive checks through internal
  helpers.
- **Surface, don't hide.** Tool use becomes Activity; cost becomes Usage;
  errors become a visible Message. The UI never silently swallows agent
  behaviour.
- **Permissions are explicit state.** Tool categories map 1:1 to Engine
  `-Disable*` switches. A Permission that is off means the corresponding switch
  is passed; the UI reflects the exact set in force for the next Turn.
- **Settings are a single object.** Model, Permissions, Projects + selected
  Project, Agents folder + selected Agent, Skill/Instruction/Prompt roots,
  reasoning effort — one settings object, read at the start of each Turn so
  changes take effect on the next prompt.
- **Derive, don't duplicate.** `workspaceFolder` is derived from the selected
  Project on every `Merge-DpSettings`, so Turn/Upload/explorer code reads one
  field while the registry stays the source of truth. A legacy direct
  `workspaceFolder` write is migrated into a registered Project.
- **Project folder chrome derives from the path.** The composer Project chip
  displays `leafName(selected.path)`, not the mutable stored Project name. Keep
  it intrinsically sized with a capped, ellipsized label and expose the full
  leaf through the hover title.
- **Engine gaps filled via the system prompt.** Concepts the Engine has no native
  parameter for (Projects, Agents) are surfaced by composing `-SystemPrompt`
  rather than changing the Engine: the selected Agent's `*.agent.md` body plus a
  note naming the Project folder.
- **Filesystem endpoints are directory-only.** The folder picker and explorer
  enumerate/create directories (never file contents); `mkdir` is single-segment
  (no separators/`..`); the explorer tree is confined to the selected Project.
- **One gate for Customization I/O.** Every Customization read, write, and create
  passes `Resolve-DpCustomizationPath`: the path must be a descendant of a
  configured root **and** match the category's file pattern. Reads/saves/creates
  never re-implement the check; they call the gate. Saves are edit-only and
  atomic (temp + `Move-Item -Force`); creates validate the name as a single safe
  segment and refuse an existing target.
- **Attachment eligibility follows the upload event.** Successful uploads are
  recorded in a per-launch, OS-case-aware registry keyed by normalized absolute
  path with MIME type. Native Vision input resolves against this registry, not
  the currently selected Project, so a pending Attachment survives Project
  switching while an arbitrary local path never reaches `Invoke-Shp -Image`.
- **Ask-User is a normalized, permission-gated Questionnaire boundary.** Keep
  built-in `ask_user` as free-text fallback; register trusted `ask_questions`
  per Turn for bundled JSON. Bound Model data before SSE/DOM, correlate answers
  by Conversation/question ids, and remove the Tool when Ask-User is off. Never
  infer Tool semantics from host colors or display text.
- **Cancellation is immediate in the UI and asynchronous at the Engine.** Freeze
  client paints on click; unwind through `BeginStop` while pumping requests;
  persist a stopped Message. Use exact Usage only with paired snapshots, else a
  labelled partial input estimate. Never treat a missing baseline as zero.
- **Every git call goes through one hardened runner.** `Invoke-DpGitCommand` owns
  the process: argument list (no shell), closed stdin, `GIT_TERMINAL_PROMPT=0`,
  `GIT_LITERAL_PATHSPECS=1`, a timeout on *every* call, deadline-bounded async
  reads, disposal. The accept loop is single-threaded, so "this git command can
  block" and "the whole UI freezes" are the same sentence.
- **A ref name is validated before git sees it, and again after it is rewritten.**
  `Test-DpGitBranchName` enforces git's own rules in plain language; anything that
  *derives* a new token (stripping a `<remote>/` prefix) re-validates, and the
  command carries `--`. A name that survived validation once is not a name.
- **Git speaks repo-relative; DeskPilot speaks Project-relative.** Porcelain and
  numstat report paths from the repository root, so `Get-DpGitChanges` rebases
  them onto the Project and drops anything outside it. Every file endpoint then
  shares one path frame, and a Project inside a bigger repository is ordinary.
- **Bound the work while building it, not after.** The change list caps as it is
  assembled and only measures what it reports. A cap applied after the loop is a
  cap that already paid for the work.
- **State the agent changed something without being asked.** A count behind a
  button and a collapsed Activity panel both fail: the changed files are listed
  under the Git bar and coloured in the tree, so the fact arrives unprompted.
- **Report a file, not a folder.** Git can collapse an untracked directory into
  one record; nothing downstream (diff, commit, undo) can act on it. Always list
  untracked files individually and bound the result instead.
- **A failed recovery is reported as failed.** An autostash restore lives in one
  place (`Restore-DpSyncStash`); when the pop fails it keeps `stashed` true, sets
  `stashPopConflict`, and names the stash. Telling a non-expert their work was
  restored when it is in `refs/stash` is worse than telling them nothing.
- **A generated prompt is a suggestion, never an action.** The conflict prompt is
  returned as text, shown in an editable box, and sent only by an explicit click.
  Its wording ("do not run git") is a guardrail, not a control - the real
  injection surface is the file content the agent then reads.

## Anti-patterns to avoid

- Parsing `Write-Host` color/ANSI to reconstruct semantics — brittle; prefer the
  structured result object for Activity and Usage.
- Binding the Host Server to `0.0.0.0` — localhost only unless explicitly opted
  in with auth.
- Leaking one Conversation's history into another via the Engine's running chat.
- Recomputing on the client what the server already computed exactly. The SPA
  reads `fileCount` / `totalAdded` / `totalDeleted` from the API; deriving them
  from a capped list silently understates the truth.
- Running two Sampler builds at once. They both write
  `output/module/DeskPilot`; the second one dies mid-build with no useful error.
