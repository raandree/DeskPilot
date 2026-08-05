# Spec 090 — Git Workbench (Changes review, Diff viewer, Branch Wizard)

> Status: implemented 2026-08-05. Extends the Git bar and spec 070 (Merge Wizard)
> into a complete, non-expert version-control surface. Companions: spec 070
> (Merge Wizard), spec 080 (Clone Wizard). Use canonical glossary terms only.

## Purpose

Give a user with no git knowledge the four things they actually need after an
agent has edited their files:

1. **See what changed** — a "N files changed +A −D" summary per Turn, and a
   repository-wide count in the Git bar.
2. **Inspect a change** — click a file, read a real diff with line numbers.
3. **Keep or undo it** — commit the change so it is safe, or revert it.
4. **Work with Branches and the server** — create, switch, delete, merge, and
   sync (pull/push), with a prepared prompt when a conflict appears.

Success: a knowledge worker reviews an agent's edits, saves them, publishes them,
and recovers from a conflict without ever opening a terminal.

## Decisions

| Topic | Decision |
| --- | --- |
| Where changes appear | A Changes card under the **newest** assistant Message, plus a repository-wide count in the Git bar. Older Turns do not paint a card: their card would describe a working tree that has since moved on, and each card costs a Git read. |
| Change source of truth | `git status --porcelain -z` for *which* files changed; `git diff HEAD --numstat -z` for line counts. Untracked files have no diff against HEAD, so their count is measured from the file (NUL byte ⇒ binary, 0 lines). |
| Path frame | Git reports repository-relative paths; every other DeskPilot file endpoint speaks **Project-relative**. `Get-DpGitChanges` rebases each path and drops anything outside the Project, so a Project that is a subdirectory of a larger repository behaves like any other. |
| Cost control | The repository-wide call collapses an untracked **folder** into one entry; only a path-filtered call expands file by file. The 500-file cap is applied **while the list is built**, and only reported files are measured. The Host Server accepts on one thread — an un-ignored `node_modules` must not become a stall. |
| Totals | `fileCount` is exact; `totalAdded` / `totalDeleted` cover the reported files, with `truncated` saying the list was capped. The SPA reads all four from the server rather than recomputing them from a capped list. |
| "Keep" semantics | A commit. Nothing else makes an agent's work durable, and nothing else can be pushed. The user supplies the message; the previous user prompt is the suggestion. |
| "Undo" semantics | Unchanged from the existing behaviour: tracked files are restored to HEAD, files the Turn created are deleted. Confirmed first. |
| Diff rendering | A modal with a file list beside a unified diff carrying **both** old and new line numbers. Parsing is a pure function (`diff.js`) so it is unit-testable without a browser. |
| Branch vocabulary | The UI says "get from server" / "send to server" / "sync"; the API and the implementation stay ordinary `pull` / `push`. |
| Branch creation | Name validated locally against git's ref rules *before* git sees it, so a bad name produces a sentence rather than a `fatal:`. Start point defaults to the current Branch. Switching after creation is the default. |
| Branch deletion | Safe `git branch -d` by default. An unmerged refusal is reported as `notMerged` with HTTP `409` so the UI can offer an explicit "Delete anyway". The Default Branch can never be deleted. Deleting the checked-out Branch switches to the Default Branch first. Remote delete is a separate opt-in with its own confirm. |
| Sync order | `sync` = pull then push. Pushing first is what produces the classic rejection a non-expert cannot read. |
| Dirty tree on pull | Blocked with reason `dirty`, then offered as "set them aside, sync, put them back" (`autostash`). A conflict *on top of* an autostash is unwound (abort + pop) and reported as `conflict-with-local-changes`, because that mixed state is unrecoverable for the target user. A restore that fails is **never** reported as restored: `stashed` stays true, `stashPopConflict` is set, and the message names the Git stash. |
| Conflict handling | Two routes, both user-approved. Inside the Merge Wizard: the Tool-free Merge Plan of spec 070. Everywhere else: DeskPilot **generates a prompt** and shows it for review; the user sends it, and the agent resolves the conflict with its File Tools. Nothing is written or sent automatically. |
| Publishing a Branch | A first push uses `push -u`, reported as `published` so the UI can say so plainly. |
| Credentials | Ambient git credential helper / SSH only. DeskPilot stores no git secrets. |
| Blocking | Every networked git call carries a timeout and runs with `GIT_TERMINAL_PROMPT=0`. The Host Server accepts on one thread, so a git command waiting for input or a dead remote would otherwise freeze the entire UI. |

## Non-goals

Staging individual hunks; amending, rebasing, cherry-picking, or editing history;
stash management as a first-class feature; tags; submodules; creating a GitHub
Pull Request; a commit-history browser; multiple remotes; resolving conflicts
without the user's approval.

## Flows

### Changes review

1. A Turn finishes and reports written files.
2. DeskPilot asks `GET /api/git/changes?paths=…` for exactly those files.
3. The card paints: `N files changed`, `+A`, `−D`, then one row per file with a
   status badge and its own counts.
4. Clicking a row opens the Diff viewer on that file, with the whole set loaded
   so the reviewer can step through with ↑/↓.
5. **Keep** asks for a message (pre-filled from the prompt) and commits exactly
   those paths. **Undo** confirms, then restores/deletes them.

### Branch Wizard

1. `Branches…` in the Git bar opens it.
2. It loads the Branch list (with a fetch, so merged badges are accurate) and the
   sync status in parallel. An unresolved conflict short-circuits straight to the
   conflict step — it is the most urgent state a repository can be in.
3. Home shows: where you are, what is unsent/unreceived, uncommitted count, and
   the Branch list with per-row Switch / Delete.
4. Actions: Sync · Get from server · Send to server · Review changes… ·
   New branch… · Merge a branch… (hands off to the Merge Wizard of spec 070).

### Conflict

1. A conflict is detected (from a sync, or found on open).
2. `GET /api/git/conflict/prompt` returns the conflicted files **and** a prepared
   prompt naming them, explaining the markers, and forbidding the agent from
   running git.
3. The user reads and may edit it, then chooses: **Copy**, **Abort the merge**,
   or **Ask DeskPilot to fix it** (which fills the composer and sends a Turn).
4. After the agent edits the files, the user reviews the result and completes the
   merge from the Changes card or the Merge Wizard.

## Implementation map

Backend helpers (each via `Invoke-DpGitCommand`, confined to
`settings.workspaceFolder`, never throwing):

- `Get-DpGitChanges` — the change set with per-file status, `+`/`−` counts and
  totals; optional path filter.
- `ConvertTo-DpProjectRelativePath` — rebases a repository-relative git path onto
  the Project, dropping anything outside it.
- `Measure-DpFileLine` — bounded line count / binary detection for untracked
  files.
- `Invoke-DpGitCommit` — stage (all, or given paths) and commit; reports
  `nothingToCommit` distinctly from an error.
- `Test-DpGitBranchName` — git's ref rules in plain language.
- `New-DpGitBranch` — create (handling an unborn HEAD) and optionally switch.
- `Remove-DpGitBranch` — safe local delete with `notMerged`, optional remote.
- `Get-DpGitSyncStatus` — ahead/behind, upstream, dirty, in-merge, conflicts.
- `Invoke-DpGitSync` — pull / push / sync with autostash and conflict reporting.
- `Restore-DpSyncStash` — the one place an autostash is put back, and the one
  place that can admit it failed.
- `New-DpConflictPrompt` — the suggested conflict-resolution prompt.

`Invoke-DpGitCommand` gained `-TimeoutSeconds` (defaulting to a ceiling rather
than "wait forever"), deadline-bounded asynchronous stream reads, a closed stdin,
process disposal, `GIT_TERMINAL_PROMPT=0` and `GIT_LITERAL_PATHSPECS=1`.

Routes (registered in `Start-DeskPilot`, handled in `Invoke-DpRouteHandler`,
behind the session token; `{ error: { code, message } }` on failure): see
[030-api-contract](030-api-contract.md) — `GET /api/git/changes`,
`POST /api/git/commit`, `POST /api/git/branch/create`,
`POST /api/git/branch/delete`, `GET /api/git/sync/status`, `POST /api/git/sync`,
`GET /api/git/conflict/prompt`.

Frontend (`web/`): `assets/diff.js` (pure parsing/formatting helpers), a Changes
card in every assistant Message, a Diff viewer modal with a file list, and a
Branch Wizard modal. The Git bar gains `Branches…` and a live change count.

## Failure modes & edge cases

git missing / not a repo → existing messaging. No remote → sync is blocked with
`no-remote` and the sync buttons explain there is nothing to sync with. Detached
HEAD → sync blocked with `detached`; the wizard says so. Unborn HEAD → branch
creation uses `checkout -b`. Push rejected as non-fast-forward → `push-rejected`
with "get the server's changes first". Stalled remote → the timeout kills git and
reports it rather than hanging the Host Server. Binary file → shown as `binary`
with no line counts and no text diff. Renamed file → reported as `renamed` with
its original path. Huge change set → capped at 500 files with `truncated`, while
the totals stay exact.

## Security

Every git call is the process-based `Invoke-DpGitCommand` (argument list, no
shell), confined to the selected Project. Branch names are validated against
git's ref rules **before** git sees them — on create *and* on delete, and again
after a `<remote>/` prefix is stripped, because stripping produces a new token —
which removes the `-`-prefixed argument-injection shape; the remote delete also
carries a `--` separator. `GIT_LITERAL_PATHSPECS=1` stops a filename that begins
with pathspec magic from changing a command's meaning. Commit and change paths
are confined to the Project folder the same way `Get-DpGitDiff` and
`Invoke-DpGitRestore` confine theirs; a path outside is skipped, never acted on,
and skipped paths are reported to the user rather than silently dropped.

The only networked privileged actions are push, fetch and remote delete, each
behind an explicit user action and using ambient credentials only. The conflict
prompt is *suggested*, never auto-sent, so the agent gains File-write scope only
when the user chooses to send it. That prompt's wording is a guardrail, not a
control: the real injection surface is the conflicted file **content** the agent
then reads, which is the pre-existing T1/T5 posture rather than something this
spec introduces. Localhost bind + session token unchanged.

Residual, inherited from the established pattern: path confinement uses a
normalized prefix comparison and does **not** resolve reparse points, so a
junction inside the Project resolves as inside it.

## Open questions

- Per-hunk staging (proposed: not in v1 — it reintroduces the vocabulary this
  spec removes).
- A commit-history view (proposed: after v1, read-only).
- Remembering the last commit message per Conversation (proposed: no).
