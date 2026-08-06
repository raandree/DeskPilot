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
- **"What did the agent change?" is not "what is uncommitted?".** DeskPilot keeps
  its own pending change set above Git: every file a Turn wrote, paired with a
  pre-Turn snapshot commit, held until the user keeps or undoes it. Undo means
  "before DeskPilot touched it", so the user's own earlier edits survive. Keep
  accepts without committing - conflating the two would make Keep irreversible.
- **Snapshot without touching anything the user owns.** The pre-Turn snapshot is
  a normal commit object written through a throwaway `GIT_INDEX_FILE` and parked
  under `refs/deskpilot/snapshots/`. No index, worktree or branch is modified,
  and the ref is deleted once nothing references it.
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

- **A backend route nobody calls is not a feature.** `POST /api/git/commit`
  shipped with the Git Workbench, was documented, and was tested — and no line of
  the SPA ever called it, so the target user had Keep and Undo but no way to make
  anything durable. Trace every user-facing promise to the click that reaches it.
- **`git add -A` has no boundary; the Project does.** Without a pathspec, `add -A`
  stages the whole repository, so a Project inside a larger repository silently
  commits its siblings. Every bulk git write carries `-- .` or an explicit path
  list, the same way every read rebases onto the Project.
- **A committed file is a reviewed file.** Committing clears exactly the files it
  wrote from the pending change set. Leaving them would keep calling a saved file
  unreviewed and offer an undo that now contradicts history — two panels
  disagreeing about the same file is worse than either panel being empty.
- **Prefill the field that stops the user.** A commit message is mandatory and is
  the exact step a non-expert stalls on, so the box opens with an honest,
  editable suggestion derived from the change set, and a ✨ button can have the
  Model write it properly. A required field with no default is a wall, not a
  prompt.
- **A Model call the user did not ask for is a bill they did not agree to.** The
  suggested Save Message runs on an explicit click, refuses while another Turn
  holds the Engine Runspace, and spends nothing on a clean tree. The free local
  suggestion is the default; the Turn is the opt-in.
- **Untrusted content reaches the Model with nothing to act with.** The
  suggested-Save-Message Turn disables every Tool, fences the file list and diff
  as data rather than instructions, bounds both, and writes the answer into an
  editable box. An injected diff can then produce a misleading sentence and
  nothing else.

- **Read git's full ref name, filter on that, shorten afterwards.**
  `%(refname:short)` abbreviates `refs/remotes/origin/HEAD` to plain `origin`, so
  a `*/HEAD` filter on the short name silently passes it through and the *remote*
  appears in the Branch list. Ask for `%(refname)`, filter, then shorten. Git's
  display forms are for humans; parse the canonical one.
- **A mock can only be as right as your belief about the tool.** The branch-list
  tests fed `origin/HEAD` into the mock — a string git never actually emits for
  that ref — so they passed while the real output was wrong. Where a helper
  parses another program's output, one test must run the real program.
- **A display preference belongs on the machine, not in Settings.** The explorer
  width joins the theme in `localStorage`: the Host Server gains nothing from
  knowing it, and a per-machine value is the right scope for something that
  depends on the monitor. Settings stays the one object that shapes a Turn.
- **Clamp for display, remember what was asked for.** The explorer keeps the
  requested width separately from the viewport-clamped one, so shrinking the
  window and widening it again restores the user's choice instead of the clamp.

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
- Returning a collection from an `if`-expression
  (`$x = if (…) { [List[T]]::new() }`). PowerShell unrolls an empty collection to
  nothing, so `$x` is `$null` and the next `.Add()` throws. Declare the list, then
  fill it. The same unrolling makes a helper that returns an empty array yield
  `$null` at the call site - wrap the call in `@(…)`.
