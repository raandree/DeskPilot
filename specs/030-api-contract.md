# 030 — API Contract

All endpoints are served by the Host Server on `http://127.0.0.1:<port>`.
Requests and responses are JSON unless noted. Errors use a common shape:

```json
{ "error": { "code": "string", "message": "human-readable" } }
```

Status codes: `200` OK, `201` Created, `204` No Content, `400` bad input,
`404` not found, `409` conflict (e.g. Turn already running), `500` server.

## Health & auth

### `GET /api/health`

```json
{
  "status": "ok",
  "version": "0.1.0",
  "engineImported": true,
  "authenticated": true,
  "model": "claude-opus-4.8",
  "engineModulePath": "C:/Users/you/Documents/PowerShell/Modules/ShellPilot/0.1.0/ShellPilot.psd1"
}
```

### `GET /api/auth/status` → `{ "authenticated": true|false }`

`authenticated` reflects whether the cached token **file** exists — a cheap
check, not a validity probe. An *expired* token still reports `true`; expiry is
detected lazily when the first Engine call fails (see `GET /api/models` → `401`
`auth_required`).

### `POST /api/auth/start` — **SSE** (`text/event-stream`)

Starts the device-code flow. Optional JSON body `{ "force": true }` re-runs the
flow even when a token file already exists (`Initialize-Shp -Force`) — required to
replace an **expired** token, since without `force` a present token
short-circuits straight to `done { "authenticated": true }`. Events:

| event | data |
| --- | --- |
| `code` | `{ "userCode": "WXYZ-1234", "verificationUri": "https://github.com/login/device", "expiresInSec": 900 }` |
| `waiting` | `{ "message": "Waiting for you to authorise in the browser…" }` |
| `done` | `{ "authenticated": true }` |
| `error` | `{ "message": "…" }` |

## Models

### `GET /api/models`

```json
{
  "default": "claude-opus-4.8",
  "models": [
    {
      "id": "claude-opus-4.8",
      "maxContextWindowTokens": 200000,
      "maxOutputTokens": 64000,
      "reasoningEfforts": ["minimal","low","medium","high","max"],
      "vision": true
    }
  ]
}
```

The Host Server caches this list. A Turn forwards the reasoning-effort Setting as
`-ReasoningEffort` only when the effective Model's `reasoningEfforts` includes it;
a Model advertising an empty list (no reasoning-effort support) never receives
it, so the Engine cannot reject the Turn with `invalid_reasoning_effort` (400).

If the cached GitHub sign-in is missing or expired, the Engine fails while
exchanging the token and this route returns `401` with
`{ "error": { "code": "auth_required", "reauth": true, "message": "…" } }`
(distinct from `502 engine_unavailable` for other Engine faults). The SPA treats
`auth_required` / `401` as the signal to open the re-sign-in overlay, which posts
`POST /api/auth/start { "force": true }`. Transient network failures are **not**
classified as auth errors, so they never trigger a spurious re-sign-in.

## Settings

### `GET /api/settings`

Returns the Settings object (see architecture spec).

### `PUT /api/settings`

Body: a partial or full Settings object. Returns the merged, persisted Settings.
Unknown fields are rejected with `400`.

The memory-and-context keys are validated on write: `autoCompaction` (boolean),
`compactionThreshold` (a fraction 0.5–0.95, rounded to 2 dp; the UI sends it as a
percent ÷ 100), and `compactionKeepRecent` (an integer 2–100). Out-of-range values
return `400`.

The update keys are validated on write: `updateCheckIntervalMinutes` (an integer
1–1440; out of range returns `400`) and `updateIncludePrereleases` (boolean). They
control the background Gallery check (see **Updates**).

Projects are managed through this endpoint: send `projects` (an array of
`{ id?, name?, path }`; a missing `id` is generated and a missing `name`
defaults to the path leaf) and/or `selectedProjectId` (must reference a known
Project, or `null`). Sending `selectedProjectId: null` **closes** the active
Project: it clears the selection and the derived `workspaceFolder` while leaving
the Project registered (distinct from removing it via `projects`). The response
includes the derived `workspaceFolder` for the selected Project (`null` when
none). A `selectedProjectId` that matches no Project returns `400`.

### `GET /api/settings/export`

Returns a backup wrapper for download:

```json
{ "type": "deskpilot-settings-backup", "version": 1,
  "exportedUtc": "2026-06-09T12:00:00Z", "settings": { /* full Settings */ } }
```

### `POST /api/settings/import`

Body: a backup wrapper (as above) or a bare Settings object. Restores by merging
onto the **defaults** (a full replace, not a patch), so settings absent from the
backup return to their defaults. The `version` and derived `workspaceFolder`
keys are ignored. Returns the restored Settings; an invalid backup returns `400`.

## Filesystem (folder picker)

These back the project folder-picker UI. Loopback + token-gated like the rest of
the API; they enumerate and create directories only (never file contents).

### `GET /api/agents`

Lists the Agents discovered under the configured Agents folder
(`settings.agentsRoot`, default `~/.copilot/agents`).

When no Agents folder is configured but the conventional `~/.copilot/agents` now
exists (for example after a CopilotAtelier setup created the junction), the route
adopts and persists it, so agents that appear after startup are listed — and a
selected Agent reaches the Turn — without a restart. The SPA also re-fetches this
endpoint on a short interval and on window focus/visibility.

```json
{
  "agents": [ { "id": "tax-researcher.agent.md", "name": "tax-researcher", "description": "…" } ],
  "selected": "tax-researcher.agent.md",
  "root": "C:/Users/me/.copilot/agents"
}
```

`id` is the file name. Selecting an Agent is done via `PUT /api/settings`
(`selectedAgent`); the selected Agent's Markdown body becomes the Turn's system
prompt.

## Customizations

Browse and edit the agent-shaping Markdown files (Agents, Skills, Instructions,
Prompt Files) under their configured roots. Every read, write, and create is
confined to a configured root **and** the category's file pattern.

### `GET /api/customizations`

Lists every Customization grouped by category, in catalog order.

```json
{
  "categories": [
    {
      "id": "agent",
      "label": "Agents",
      "count": 2,
      "roots": [ "C:/Users/me/.copilot/agents" ],
      "items": [
        { "id": "C:/Users/me/.copilot/agents/legal-researcher.agent.md",
          "category": "agent", "name": "legal-researcher",
          "description": "German law research…",
          "path": "C:/Users/me/.copilot/agents/legal-researcher.agent.md",
          "root": "C:/Users/me/.copilot/agents", "scope": "User" }
      ]
    },
    { "id": "skill", "label": "Skills", "count": 0, "roots": [], "items": [] },
    { "id": "instruction", "label": "Instructions", "count": 0, "roots": [], "items": [] },
    { "id": "prompt", "label": "Prompt files", "count": 0, "roots": [], "items": [] }
  ]
}
```

`name` is the frontmatter `name` when present, otherwise the file stem (or, for a
skill, the folder that holds its `SKILL.md`). `scope` is `User` for files under
`~/.copilot`, otherwise `Workspace`.

### `GET /api/customizations/content?category=<id>&path=<file>`

Returns the file's UTF-8 text for the editor. A missing `category`/`path` is a
`400`; an invalid category, a path outside the configured roots, a name that does
not match the category pattern, or a missing file is reported in `error` (HTTP
`200`). A file over the 1 MiB cap is flagged `truncated`; a NUL-byte file is
flagged `binary`. Both open read-only.

```json
{ "category": "agent", "path": "C:/Users/me/.copilot/agents/legal-researcher.agent.md",
  "name": "legal-researcher.agent.md", "bytes": 4096,
  "truncated": false, "binary": false, "text": "---\nname: …", "error": null }
```

### `PUT /api/customizations/content`

Body `{ "category": "<id>", "path": "<file>", "text": "<new contents>" }`.
Overwrites an **existing** Customization atomically (UTF-8, no BOM). Returns
`{ "ok": true, "path": "…", "bytes": 4096 }`. A path outside the roots, a pattern
mismatch, a missing file, or an over-size payload returns `400`.

### `POST /api/customizations`

Body `{ "category": "<id>", "name": "<segment>", "root"?: "<configured root>" }`.
Creates a new Customization from the category scaffold in a configured root
(`<root>/<name><suffix>`, or `<root>/<name>/SKILL.md` for a skill) and returns
`201` with `{ "category", "name", "path", "root" }`. `name` must be a single safe
path segment (letters, digits, dot, dash, underscore); an invalid name, a missing
configured root, an unknown `root`, or an existing target returns `400`.

### `GET /api/fs/list?path=<dir>`

Lists the immediate sub-folders of `path` (hidden/system entries skipped). An
empty or non-existent `path` falls back to the user's home folder.

```json
{
  "path": "C:/Users/me/code",
  "parent": "C:/Users/me",
  "name": "code",
  "entries": [ { "name": "deskpilot", "path": "C:/Users/me/code/deskpilot" } ],
  "drives": [ "C:\\", "D:\\" ],
  "home": "C:/Users/me",
  "error": null
}
```

`parent` is `null` at a drive root. An enumeration failure (for example access
denied) is reported in `error` while `parent`/`drives` stay usable.

### `GET /api/fs/tree?path=<dir>`

Backs the project file explorer. Lists the folders and files directly inside
`path` (folders first, then files; hidden/system skipped), confined to the
selected Project's folder (`settings.workspaceFolder`). Returns `400` when no
Project is selected; a `path` outside the Project folder yields an `error`.

```json
{
  "path": "C:/proj/src",
  "root": "C:/proj",
  "entries": [
    { "name": "lib", "path": "C:/proj/src/lib", "type": "dir" },
    { "name": "app.ts", "path": "C:/proj/src/app.ts", "type": "file", "bytes": 2048 }
  ],
  "error": null
}
```

### `POST /api/fs/mkdir`

Body `{ "parent": "<dir>", "name": "<segment>" }`. Creates `parent/name` and
returns the listing of the new folder (same shape as `GET /api/fs/list`). `name`
must be a single path segment; separators, `..`, and invalid characters are
rejected with `400`.

## Git (selected Project)

These operate on the selected Project's folder (`settings.workspaceFolder`) only.
Each runs `git` via a process call (no shell, so no argument injection).

### `GET /api/git/status`

```json
{ "gitAvailable": true, "isRepo": true, "branch": "main", "detached": false,
  "branches": [ "main", "feature" ], "root": "C:/proj", "error": null }
```

`gitAvailable` is `false` when git is not installed. When `isRepo` is `false` the
folder is not a Git work tree. `detached` is `true` for a detached HEAD, where
`branch` is a short commit id.

### `POST /api/git/init`

Runs `git init` in the Project folder and returns the new status (same shape as
`GET /api/git/status`). `400` when no Project is selected or git init fails.

### `POST /api/git/checkout`

Body `{ "branch": "<name>" }`. Switches to an **existing** local branch (validated
against the live branch list) and returns the new status. `400` for an unknown
branch or no Project; `409` when the checkout fails (for example uncommitted
changes would be overwritten).

## Git Workbench (selected Project)

These power the Changes review, the Diff viewer and the Branch Wizard (spec 090).

### `GET /api/git/diff?path=<file>[&base=<sha>]`

Returns the working-tree diff of one file. With `base`, the diff is taken against
that commit instead of HEAD, which is how the Changes review shows *what the
agent did* rather than everything since the last commit. `base` is honoured only
when it is one of this Project's own pending-change snapshots, so the query
cannot name an arbitrary commit to read from.

### `GET /api/git/changes`

Optional query `paths=<newline-separated list>` restricts the result to those
files (relative to the Project, or absolute inside it; a path outside is ignored).
A path can contain a comma or a semicolon on every supported platform but never a
newline, which is why the separator is a newline.

```json
{ "gitAvailable": true, "isRepo": true, "branch": "main",
  "files": [
    { "rel": "src/app.js", "from": null, "status": "modified", "staged": false,
      "directory": false, "added": 12, "deleted": 4, "binary": false },
    { "rel": "notes.md", "from": null, "status": "untracked", "staged": false,
      "directory": false, "added": 30, "deleted": 0, "binary": false }
  ],
  "fileCount": 2, "totalAdded": 42, "totalDeleted": 4, "truncated": false,
  "error": null }
```

`status` is one of `added`, `modified`, `deleted`, `renamed`, `untracked`,
`conflicted`. Line counts come from `git diff HEAD --numstat`; an untracked file
has no diff against HEAD, so its count is measured from the file itself (a NUL
byte makes it `binary` with zero lines).

`rel` is **Project-relative**, matching every other file endpoint. Git reports
paths relative to the repository root, so when the Project is a subdirectory of a
larger repository the paths are rebased and anything outside the Project is
dropped.

Untracked files are listed **individually** (`--untracked-files=all`): the
collapsed form reports a bare folder, which is not something a diff or a commit
can act on. Git's own ignore rules keep that walk cheap.

The list is capped at 500 files **while it is built** (`truncated: true`) and only
reported files are measured. `fileCount` is exact; `totalAdded` and
`totalDeleted` cover the returned files.

### `POST /api/git/commit`

Body `{ "message": "<text>", "paths": [ "<rel>", … ] }`. Stages the given files
(or everything inside the Project when `paths` is omitted) and commits. This is
the **Save** action: it is what makes an agent's edits durable and pushable.

```json
{ "committed": true, "sha": "…", "shortSha": "a1b2c3d",
  "summary": "[main a1b2c3d] keep the edit", "nothingToCommit": false,
  "skipped": [], "files": [ "src/app.js" ], "kept": 1, "error": null }
```

`files` lists what the commit contained, Project-relative like every other file
endpoint. A bulk save stages `git add -A -- .` rather than the whole repository,
so a Project that is a subdirectory of a larger repository never drags the rest
of it into the commit.

`kept` is how many of those files left the pending change set: a committed file
is a reviewed file, so it stops being reported as an unreviewed DeskPilot change
(see `POST /api/changes/keep`).

`nothingToCommit` is `true` (with `committed: false` and no error) when there was
nothing staged. `400` for an empty message, a merge in progress, or when no given
path is inside the Project.

### `POST /api/git/commit/message`

Asks the Model for the one line the Save dialog requires. Body is empty; the
change set is read server-side.

```json
{ "message": "Update the quarterly report", "fileCount": 8 }
```

A pure-reasoning Turn with every Tool disabled (like the Merge Plan), prompted
with the file list and a bounded excerpt of `git diff HEAD -- .`. The result is
cleaned to a single short line. It runs only on an explicit click — it costs a
Turn — and only ever fills an editable box.

`400 nothing_to_save` on a clean tree (no Turn is spent), `409 turn_running`
while another Turn holds the Engine Runspace, `502 engine_error` when the Engine
fails, and `502 no_suggestion` when the answer cleans to nothing.

### `POST /api/git/branch/create`

Body `{ "name": "<name>", "from": "<ref>", "checkout": true }`. The name is
validated against git's ref rules **before** git sees it, so a bad name yields a
sentence rather than a `fatal:`. `from` defaults to the current HEAD; a repository
with no commits yet is created with `checkout -b`.

```json
{ "created": true, "checkedOut": true, "name": "draft-report",
  "from": "main", "error": null }
```

`400` for an invalid name, an existing branch, or an unknown starting point.

### `POST /api/git/branch/delete`

Body `{ "name": "<name>", "force": false, "deleteRemote": false }`. Refuses the
Default Branch. Switches to the Default Branch first when the branch to delete is
checked out. Uses the safe `git branch -d` unless `force` is set.

```json
{ "name": "draft-report", "deleted": true, "notMerged": false,
  "switchedTo": "main", "remoteDeleted": false, "remoteError": null,
  "error": null }
```

`409` with `error.notMerged: true` when the branch has commits that are not in the
Default Branch, so the caller can offer an explicit force. The remote delete is
opt-in and reported separately so a remote failure never undoes the local result.

### `GET /api/git/sync/status`

Optional query `fetch=1` refreshes the remote-tracking refs first (best effort).

```json
{ "gitAvailable": true, "isRepo": true, "branch": "main", "detached": false,
  "hasRemote": true, "remoteName": "origin", "upstream": "origin/main",
  "hasUpstream": true, "ahead": 2, "behind": 1, "dirty": true,
  "changeCount": 3, "inMerge": false, "conflictFiles": [],
  "fetched": true, "fetchError": null, "error": null }
```

With no upstream, `ahead` counts the commits that are not on the remote's Default
Branch, so the UI can say "N saves have never been sent" instead of "no upstream".

### `POST /api/git/sync`

Body `{ "action": "pull" | "push" | "sync", "autostash": false }`. `sync` pulls
then pushes — pushing first is what produces the rejection a non-expert cannot
read. A pull fast-forwards when it can and otherwise creates a merge commit. A
first push uses `push -u` and reports `published`.

```json
{ "status": "success", "action": "sync", "branch": "main",
  "upstream": "origin/main", "published": false, "pulled": true,
  "pushed": true, "fastForward": true, "ahead": 0, "behind": 0,
  "conflictFiles": [], "stashed": false, "stashPopConflict": false,
  "reasons": [], "error": null }
```

`status` is `success`, `conflict` (with `conflictFiles`), `blocked` (with
`reasons`: `dirty`, `detached`, `in-merge`, `no-remote`, `push-rejected`,
`conflict-with-local-changes`), or `error`. A dirty tree blocks a pull unless
`autostash` is set; a conflict *on top of* an autostash is unwound (abort + pop)
and reported as `conflict-with-local-changes`, because that mixed state is not
recoverable by the target user. Whenever a set-aside restore fails, `stashed`
stays `true`, `stashPopConflict` is set, and the message says the work is still
in the Git stash — never that it was restored.

Networked git runs with a timeout and with `GIT_TERMINAL_PROMPT=0`, so a stalled
remote or a credential prompt can never hang the single-threaded Host Server.

### `GET /api/git/conflict/prompt`

Optional query `branch=<incoming ref>` names the incoming side in the text.
Returns the conflicted files and a **prepared prompt** the user can review, edit
and send so the agent resolves the conflict with its File Tools. DeskPilot never
sends it automatically.

```json
{ "inMerge": true, "files": [ "shared.txt" ], "sourceBranch": "origin/main",
  "targetBranch": "main", "prompt": "Please resolve the Git merge conflicts…" }
```

## Pending DeskPilot changes (selected Project)

The layer above Git: files DeskPilot wrote that the user has not yet kept or
undone. Each carries the **snapshot** taken before the Turn that first changed
it, so "undo" means "back to how it was before DeskPilot touched it" rather than
"back to the last commit". The set is keyed by Project folder and persisted in
`changes.json`, so it survives a reload, a restart, and switching Conversations.

### `GET /api/changes`

```json
{ "files": [
    { "rel": "src/app.js", "snapshotSha": "…", "conversationId": "c_1",
      "firstSeenUtc": "2026-08-06T00:10:00.000Z", "status": "modified",
      "added": 12, "deleted": 4, "binary": false, "undoable": true,
      "existedBefore": true }
  ],
  "fileCount": 1, "totalAdded": 12, "totalDeleted": 4, "undoable": true,
  "error": null }
```

`status` is `modified`, `added` (DeskPilot created it), `deleted` (it is gone) or
`unchanged` (the user has already put it back by hand). Counts are measured
against the snapshot, not against HEAD. `undoable` is `false` for a Project that
is not a Git repository — the files are still listed, but there is nothing to go
back to. No Project selected returns an empty set rather than an error.

### `POST /api/changes/keep`

Body `{ "paths": [ "<rel>", … ] }`, or `{}` for the whole set. Accepts the changes
and stops tracking them; the files are left exactly as they are. It deliberately
does **not** commit — committing is a separate decision (**Save**, see
`POST /api/git/commit`), and conflating the two would make "keep" irreversible.
Snapshot refs no longer referenced by a remaining entry are deleted.

```json
{ "kept": 3, "remaining": 0, "changes": { … same shape as GET … } }
```

### `POST /api/changes/undo`

Body `{ "paths": [ "<rel>", … ] }`, or `{}` for the whole set. Restores each file
from its snapshot with `git restore --worktree --source=<sha>` (the working tree
only, so a staged change the user prepared themselves is untouched), and deletes
a file that did not exist in the snapshot. Only files that actually went back
stop being tracked; anything that failed stays in the set with a reason.

```json
{ "restored": [ "src/app.js" ], "removed": [ "notes.md" ],
  "skipped": [ { "path": "locked.txt", "reason": "…" } ],
  "changes": { … same shape as GET … } }
```

`400` when the Project is not a Git repository, because there is no snapshot to
restore from.

## Merge Wizard (selected Project)

These power the non-expert Branch Merge Wizard (spec 070). All operate on the
selected Project's folder only and run `git` via a process call. The **Default
Branch** is resolved as `origin/HEAD`, else `main`, else `master`.

### `GET /api/git/branches`

Optional query `fetch=1` fetches from origin first so merged status reflects the
remote (best effort; degrades to a local comparison on failure). Returns the
branch picker data:

```json
{ "isRepo": true, "currentBranch": "feature", "defaultBranch": "main",
  "hasRemote": true, "fetched": true, "fetchError": null,
  "branches": [
    { "name": "feature", "display": "feature", "isRemote": false,
      "isCurrent": true, "isDefault": false, "hasLocal": true, "merged": false },
    { "name": "origin/release", "shortName": "release", "isRemote": true,
      "isCurrent": false, "isDefault": false, "hasLocal": false, "merged": true }
  ], "error": null }
```

`merged` is `true` when the Branch is already in the Default Branch, `false` when
not, or `null` when it could not be computed.

### `GET /api/git/merge/preview?branch=<name>`

Previews merging `<branch>` into the Default Branch. Returns the incoming commits
(the delta) plus preconditions:

```json
{ "isRepo": true, "sourceBranch": "feature", "defaultBranch": "main",
  "commits": [ { "sha": "…", "shortSha": "a1b2c3d", "author": "…", "date": "…",
                 "subject": "add feature file" } ],
  "commitCount": 1, "truncated": false, "dirty": false, "behind": false,
  "behindCount": 0, "fastForward": true, "alreadyMerged": false,
  "sameBranch": false, "hasRemote": true, "error": null }
```

`alreadyMerged` is `true` when there is nothing to merge; `sameBranch` is `true`
when `branch` is the Default Branch itself.

### `POST /api/git/merge`

Body `{ "branch": "<name>", "autofix": false }`. Switches to the Default Branch and
merges (fast-forward, else a merge commit), capturing the pre-merge commit id for
undo. With `autofix` it stashes local changes and fast-forwards the Default Branch
from origin first. Returns a `status` of `success`, `already-merged`, `conflict`
(with `conflictFiles`), `blocked` (with `reasons`: `dirty`, `behind`,
`pull-diverged`, `conflict-with-local-changes`), or `error`:

```json
{ "status": "conflict", "defaultBranch": "main", "sourceBranch": "feature",
  "preMergeSha": "…", "mergedSha": null, "fastForward": false,
  "conflictFiles": [ "conflict.txt" ], "stashed": false, "pulled": false,
  "stashPopConflict": false, "reasons": [], "error": null }
```

### `POST /api/git/merge/plan`

Body `{ "branch": "<source name>" }`. Reads the in-progress merge's conflicted
files, then runs a **pure-reasoning Turn with all Tools disabled** to propose a
**Merge Plan** for the text files. Binary conflicts are returned separately for a
keep-ours / keep-theirs choice (the model is not asked to resolve them). `409`
when another Turn is running; `400` when no merge is in progress; `502` on an
Engine error.

```json
{ "inMerge": true, "sourceBranch": "feature", "defaultBranch": "main",
  "textFiles": [ { "rel": "conflict.txt", "truncated": false } ],
  "binaryFiles": [ { "rel": "logo.png" } ],
  "plan": { "ok": true,
            "resolutions": [ { "path": "conflict.txt", "content": "<full file>" } ],
            "notes": "merged both sides", "error": null } }
```

### `POST /api/git/merge/apply`

Body `{ "resolutions": [ { "path", "content" } ], "binaryChoices": [ { "path",
"choice": "ours|theirs" } ], "popStash": false }`. Writes each resolved file
(path-confined), applies binary choices, verifies no conflicts remain, then
commits the merge. `400` (with `result`) when a path escapes the Project or
conflicts remain.

### `POST /api/git/merge/abort`

Body `{ "popStash": false }`. Runs `git merge --abort`, optionally restoring an
autostash. Returns `{ "ok": true, "stashPopConflict": false, "error": null }`.

### `POST /api/git/merge/undo`

Body `{ "sha": "<pre-merge commit id>" }`. Hard-resets the Default Branch to the
captured pre-merge commit (local only; the caller warns when already pushed).
`400` for an invalid or unknown commit id.

### `POST /api/git/cleanup`

Body `{ "branch": "<name>", "deleteRemote": false, "pushDefaultBranch": false,
"force": false }`. Deletes the local Branch (switching to the Default Branch
first if needed). The networked actions are **opt-in** and reported separately so
a remote failure never undoes the local result — `pushDefaultBranch` pushes the
Default Branch, `deleteRemote` deletes the Branch on the remote, both using
ambient git credentials:

```json
{ "defaultBranch": "main", "localDeleted": true, "localSkipped": false,
  "localError": null, "defaultPushed": false, "pushError": null,
  "remoteDeleted": false, "remoteError": null, "error": null }
```

## Conversations

### `GET /api/conversations`

```json
{ "conversations": [
  { "id": "c_8f1", "title": "Summarise the Q2 notes",
    "createdUtc": "2026-06-08T10:00:00Z", "updatedUtc": "2026-06-08T10:05:00Z",
    "messageCount": 4, "model": "claude-opus-4.8",
    "pinned": false, "archived": false, "unread": false, "color": null }
] }
```

The list is sorted pinned-first, then by `updatedUtc` descending. `unread` and
`color` are organisational fields carried on every summary (and on search results).

### `POST /api/conversations`

Body (optional): `{ "title": "…", "model": "…" }`. Returns `201` with the new
Conversation summary.

### `GET /api/conversations/{id}`

```json
{
  "id": "c_8f1",
  "title": "Summarise the Q2 notes",
  "model": "claude-opus-4.8",
  "messages": [
    { "id": "m_1", "role": "user", "text": "…", "createdUtc": "…",
      "checkpoint": { "sha": "…", "root": "…", "createdUtc": "…" } },
    { "id": "m_2", "role": "assistant", "text": "…",
      "reasoning": "… or null",
      "activity": { "filesRead": [], "filesWritten": [], "commandsRun": [],
                    "pagesFetched": [], "questionsAsked": [], "toolCalls": [] },
      "tasks": [
        { "id": 1, "title": "Read the Q2 notes", "status": "completed" },
        { "id": 2, "title": "Summarise key risks", "status": "in-progress" }
      ],
      "usage": { "promptTokens": 0, "completionTokens": 0, "totalTokens": 0,
                 "costUSD": 0.0, "credits": 0.0, "priced": true },
      "model": "claude-opus-4.8", "durationMs": 0, "createdUtc": "…" }
  ]
}
```

`priced` is `false` when the Engine has no published rate for the Model — its
price table is keyed by exact Model id, so a Model newer than the table yields
`null` cost and credits. DeskPilot stores those as `0.0` but keeps the flag, so
the UI can say "cost unknown" instead of a confident `$0.0000`.

### `DELETE /api/conversations/{id}`

Returns `204`. Also removes the Conversation from the persisted store.

### `PATCH /api/conversations/{id}`

Body: `{ "title"?: "…", "model"?: "…", "pinned"?: bool, "archived"?: bool, "unread"?: bool, "color"?: "red|amber|green|teal|blue|purple|null" }`.
Returns the updated summary (including `pinned`, `archived`, `unread`, `color`).
Providing a `title` also **locks** it (`titleLocked`), so auto-titling never
overwrites a name the user chose. `pinned` / `archived` / `unread` / `color` are
organisational flags and do **not** bump `updatedUtc` (toggling them never
reorders the list). An unknown `color` is rejected with `400 bad_color`; an empty
or absent `color` clears the label.

### `POST /api/conversations/{id}/duplicate`

Duplicates the Conversation into a brand-new one that copies the title (prefixed
`Copy of `), Messages, and history but shares no state with the original. The copy
is never pinned/archived/unread and its title is locked. Returns `201` with the new
Conversation summary; `404` if the source is missing.

### `POST /api/conversations/read-all`

Clears the `unread` flag on every Conversation in one request. Returns
`{ "ok": true, "cleared": <count> }`. Registered before the `/{id}` routes so the
literal `read-all` path matches ahead of the `{id}` wildcard.

## Sending a Turn — **SSE**

### `POST /api/conversations/{id}/messages`

Body: `{ "prompt": "…", "images"?: ["C:/path/uploaded-image.png"] }`. Response
is `text/event-stream`. `images` contains paths returned by `POST /api/uploads`
during the current Host Server launch. Each path must be absolute, still exist,
and be registered with an `image/*` content type; a Project change after upload
does not invalidate it. Valid paths are passed to the Engine's native `-Image`
parameter. An unregistered, relative, missing, or non-image path returns
`400 invalid_attachment`. Returns `409` if a Turn is already running.

| event | data | when |
| --- | --- | --- |
| `start` | `{ "messageId": "m_3" }` | Turn accepted; assistant Message id allocated. |
| `delta` | `{ "text": "partial answer…" }` | each streamed answer chunk. |
| `file` | `{ "path": "docs/notes.md" }` | the agent is writing this file. Emitted from the Engine's structured tool-call record **before** the write happens, so it states intent and carries no counts; the client lists it under the Message and the Changes card supersedes the list on `done`. One frame per `write_file` call; a call whose arguments carry no usable path emits nothing. |
| `tasks` | `{ "tasks": [ { "id": 1, "title": "…", "status": "in-progress" } ] }` | Task List update during the Turn; the **full** list is sent each time (idempotent replace, not a delta). At most one Task is `in-progress`. Status is one of `not-started`, `in-progress`, `completed`. |
| `question` | `{ "id": "…", "structured": true, "title": "Profile", "questions": [{ "header": "Location", "question": "Where?", "options": [{ "label": "Munich", "description": "Within 30 km" }], "multiSelect": false, "allowFreeformInput": true }] }` | Ask-User is waiting. The client renders a Questionnaire wizard. Plain Engine text is normalized to one free-text step with `structured: false`. |
| `stopping` | `{ "message": "Turn stopped." }` | Stop was accepted; the client immediately freezes the live Message while the Engine pipeline unwinds. |
| `stopped` | stopped assistant Message | Cancellation complete. Persisted with `stopped: true`, `stopReason`, partial Usage, and the Thinking trace that streamed before the Stop (the Engine result never arrives, so `.Reasoning` is unavailable). When the Engine has no final Usage record, `usage.estimated: true` and `estimateScope: "input-only"` mark the preflight input estimate. |
| `done` | full assistant Message (same shape as in `GET conversation`) | Turn complete. The Message's `tasks` field is the authoritative final list (possibly empty). |
| `error` | `{ "message": "…" }` | Turn failed; history unchanged. |

The `tasks` event is emitted only when the `taskTracking` Setting is on. The
live frames originate from structured progress events on the Engine
Runspace's Information stream; see [020-architecture.md](020-architecture.md#in-turn-task-list).

Client stops a Turn with `POST /api/conversations/{id}/stop` → `202`. The single
accept thread services this request mid-Turn (the streaming loop pumps pending
connections), so the cancel flag is set while the Turn is still running; the Turn
then stops the Engine pipeline asynchronously. The browser switches to
**Stopping…** as soon as the button is clicked, ignores any buffered deltas, and
receives `stopping` followed by `stopped`. The stopped Message is persisted so
its Usage footer survives refresh. ShellPilot receives provider token counts in
the final stream frame, which a hard stop may prevent; when no exact Engine Usage
delta exists, DeskPilot records and labels an input-only preflight estimate
instead of displaying zero or presenting the estimate as exact.

### `POST /api/conversations/{id}/question`

Supplies an answer while Ask-User is blocking the active Turn. A plain fallback
uses `{ "questionId": "…", "answer": "Berlin" }`. A structured Questionnaire
serializes its answer object into the string field:
`{ "questionId": "…", "answer": "{\"answers\":[{\"header\":\"Location\",\"selectedOptions\":[\"Munich\"],\"freeText\":\"\"}]}" }`.
Returns `202` with
`{ "accepted": true }`, after which the Engine resumes the same Turn and the
original SSE response stays open. Returns `400 bad_answer` for a missing id or
blank answer, `404` for an unknown Conversation, and `409 stale_question` when
there is no matching pending question. Both the Conversation id and random
question id must match, so a delayed response cannot answer another Turn.

### `POST /api/conversations/{id}/title`

Generates a concise AI **title** for a new Conversation from its first prompt —
the way GitHub Copilot renames a new chat to a short summary. Body: `{}`. Returns
`{ "id": "…", "title": "…" }`. Best-effort and safe to call after any Turn:

- Returns the current title unchanged when it is **locked** (`titleLocked`, i.e. a
  manual rename) or when the Conversation is past its first exchange (more than one
  user Message).
- Returns `409` if a Turn is already running (the title Turn shares the single
  Engine Runspace).
- Otherwise runs a pure-reasoning Turn with **all Tools disabled** to summarise the
  first prompt into a few words, cleans the result (`ConvertFrom-DpTitleResult`),
  and persists it. Any Engine failure leaves the existing fallback title (the
  truncated first prompt) untouched.

The SPA calls this once, right after the first Turn of a new Conversation
completes; the sidebar and title field update in place when it returns.

### `POST /api/conversations/{id}/compact`

Compacts the Conversation's replayed context — the way GitHub Copilot offers
"Compact Conversation". Summarises the earlier part of the Engine `-History` into a
short briefing (a pure-reasoning Turn with **all Tools disabled**, cleaned by
`ConvertFrom-DpCompactionResult`) and keeps only the most recent entries verbatim
(`Compress-DpConversationHistory`), so future Turns replay far fewer tokens. How
many recent entries stay verbatim is the `compactionKeepRecent` Setting (default 4,
clamped 2–100), so the same knob drives the manual action and the automatic one. The
visible transcript (`messages`) is left untouched — nothing the user sees is lost;
only what is replayed to the Engine shrinks. Body: `{}`.

- `404` if the Conversation is missing; `409` if a Turn is running (the compaction
  Turn shares the single Engine Runspace); `400 too_short` when there is too little
  history to be worth summarising; `502 compaction_failed` if the summary comes
  back empty.
- On success, replaces `history`, sets `compactedUtc`, persists, and returns
  `{ "ok": true, "summarised": <n>, "kept": <n>, "before": <n>, "after": <n>, "estimatedFreed": <tokens>, "compactedUtc": "…" }`. Like the organisational flags,
  `compactedUtc` does not bump `updatedUtc` (it changes only the replayed context,
  not the visible thread).
- **Auto-compaction** (FR-C19) reuses this exact route: after a Turn, when the
  `autoCompaction` Setting is on and the measured occupancy reaches
  `compactionThreshold`, the SPA `POST`s here itself (mirroring auto-titling). A
  `400 too_short` is treated as a silent no-op, so a single large Turn near the
  limit never spams the user.

The new nullable `compactedUtc` Conversation field is carried on the `list` and
`GET conversation` summaries and persisted through the store.

### `POST /api/conversations/{id}/checkpoint`

Restores a **Checkpoint**: takes the Conversation back to the moment just before
a prompt was sent. Body: `{ "messageId": "m_3", "skipFiles"?: false }`.

DeskPilot already commits a pre-Turn snapshot of the Project to
`refs/deskpilot/snapshots/<assistantMessageId>` so a single file can be undone.
A Checkpoint makes that same commit reachable from the transcript: every user
Message taken while a Project was selected carries
`checkpoint: { "sha": "…", "root": "…", "createdUtc": "…" }`, which the SPA
renders as a **Restore Checkpoint** divider above the Message.

The sha is only known once the snapshot has been taken, which is after the
`start` frame, so a live Turn's optimistic bubble cannot carry it. The SPA fills
the divider in from the post-Turn `refreshCurrentConversation`, not from the
stream.

Restoring does two things:

1. **Truncates the Conversation** at that Message — it and every later Message
   are dropped and the replayed `history` is rebuilt
   (`Reset-DpConversationForRerun`, the same machinery as Regenerate and Edit).
   The removed prompt comes back in `prompt` so the SPA can refill the composer.
2. **Puts back the files those Turns wrote** — collected from each discarded
   assistant Message's `activity.filesWritten`, restored from the snapshot
   commit via the per-file undo path. A file the agent created is deleted,
   because it was not in the snapshot.

The file restore is deliberately **bounded to what the agent wrote**. It is not a
`git reset` or a folder-wide checkout, so edits the user made by hand in the
meantime survive — the same boundary the pending change set draws between "undo
what the AI did" and "revert to the last commit" (see
[090-git-workbench.md](090-git-workbench.md)). Paths outside the Project are
never touched. Once restored, those files are no longer pending changes.

Because a Checkpoint outlives the pending entries that created its snapshot,
`Remove-DpChangeEntry` skips any snapshot ref still referenced by a Message
(`Get-DpCheckpointSha`); otherwise Keeping a change would delete the commit its
own Checkpoint restores from.

- `404` if the Conversation is missing; `409` if a Turn is running.
- `400 bad_request` for a missing `messageId`; `400 checkpoint_failed` when the
  Message is gone, is not a user Message, or the git restore failed — in which
  case the Conversation is left untouched.
- `skipFiles: true` truncates the Conversation only.
- On success returns
  `{ "ok": true, "prompt": "…", "restored": [], "removed": [], "skipped": [], "files": bool }`,
  persists both stores, and bumps `ConversationsRevision` so the sidebar refreshes.
- A Conversation with no Project, or a Project that is not a Git repository, has
  no snapshot; it is still truncated and `files` is `false`.

### Mid-Turn dispatch (client-only UX)

The Engine has no notion of mid-Turn injection: a `POST /messages` call while a
Turn is running returns `409`. To give the user a richer "what now?" affordance
without changing the wire contract, the SPA implements three dispatch methods
**purely client-side** on top of the existing endpoints:

- **Stop and Send** — calls `POST /stop`, awaits SSE close, then issues a
  fresh `POST /messages` with the typed prompt as the next Turn.
- **Add to Queue** (Alt+Enter) — buffers the typed prompt in-memory; once the
  current Turn's SSE stream ends, the SPA fires a fresh `POST /messages` for
  it. Multiple queued items chain (one Turn at a time, never overlapping).
- **Steer with Message** (Enter, default while streaming) — same as Queue,
  but the prompt sent to the server is prefixed with a steering preamble so
  the Model knows the user wrote it while a previous Turn was still running:

  ```text
  [Steering note — the user sent this while a previous turn was running.
  Treat it as a course-correction or addendum to the previous turn.]

  <user-typed-text>
  ```

The pending queue is transient and never persisted; the user's message is
written to history only when its Turn actually starts. The user bubble in the
thread carries a small `Steered mid-turn` or `Sent from queue` badge so the
provenance is visible after the fact.

## Usage

### `GET /api/usage`

Returns the **session** counter (reset each launch), the persisted **lifetime**
counter (never reset automatically), the session per-Model breakdown, and a
**daily** series (up to the 60-day retention window of the persisted history,
oldest first) for the usage graph. The popover charts a 7-, 14- or 30-day window
from this series client-side. `promptTokens`/`completionTokens` on both counters
give the tokens-in/tokens-out split; `byModel` feeds the Top-models list. Credits
are rounded to 4 decimals and cost to 6 to avoid floating-point drift.

```json
{
  "session":  { "promptTokens": 0, "completionTokens": 0, "totalTokens": 0,
                "costUSD": 0.0, "credits": 0.0, "turns": 0, "unpricedTurns": 0 },
  "lifetime": { "promptTokens": 0, "completionTokens": 0, "totalTokens": 0,
                "costUSD": 0.0, "credits": 0.0, "turns": 0, "unpricedTurns": 0,
                "sinceUtc": "2026-06-01T00:00:00Z" },
  "byModel": [ { "model": "claude-opus-4.8", "totalTokens": 0,
                 "costUSD": 0.0, "credits": 0.0, "turns": 0, "unpricedTurns": 0 } ],
  "daily":   [ { "date": "2026-06-09", "credits": 0.31, "costUSD": 0.0031,
                 "totalTokens": 1200, "turns": 2 } ]
}
```

`unpricedTurns` counts the Turns whose Model the Engine had no rate for. Those
Turns add nothing to `costUSD` and `credits`, so a non-zero count means the money
figures are a **lower bound**, not the total. A counter written before this field
existed reads back as `0`.

### `POST /api/usage/reset`

Resets a counter to zero. Body: `{ "scope": "lifetime" | "session" }`
(defaults to `lifetime`). Resetting `lifetime` also sets a new `sinceUtc` and
rewrites `lifetime-usage.json`. Returns the same payload as `GET /api/usage`.

## Updates

DeskPilot checks the PowerShell Gallery for a newer release in a background job
(never inline on the accept thread) and surfaces the result **only in the web
UI**. The check is paced by `updateCheckIntervalMinutes` (default 5) and can be
forced on demand. The newest **stable** release is the default target; a preview
is offered only when `updateIncludePrereleases` is on and it is strictly newer
than both the running version and the newest stable (`Get-DpUpdateStatus`).

### `GET /api/update`

Returns the cached update status (`Get-DpUpdatePayload`):

```json
{
  "currentVersion": "0.2.0",
  "latestStable": "0.3.0",
  "latestPrerelease": null,
  "includePrereleases": false,
  "intervalMinutes": 5,
  "updateAvailable": true,
  "targetVersion": "0.3.0",
  "targetIsPrerelease": false,
  "notice": "DeskPilot 0.3.0 is available (installed: 0.2.0).",
  "checkedUtc": "2026-07-09T12:00:00Z",
  "checking": false,
  "installing": false,
  "installResult": null
}
```

### `POST /api/update/check`

Forces an immediate background Gallery check (unless one is already running) and
returns the current `GET /api/update` payload with `202 Accepted`. The SPA polls
`GET /api/update` until `checking` clears. Drives the **Check for updates** button.

### `POST /api/update/install`

Consent-gated self-update. Installs the newest DeskPilot **and** ShellPilot into
the CurrentUser scope via `Invoke-DpSelfUpdate`; when the target is a preview
(`targetIsPrerelease`), prereleases are allowed for **both** modules, otherwise
both are pinned to stable. It then **force-reloads ShellPilot live in the Engine
Runspace** (`Update-DpEngineModule`), so the Engine update takes effect at once
(safe because the runspace runs only Engine cmdlets, the token is on disk, and the
Model is passed per Turn). DeskPilot's own host code cannot hot-swap in-process, so
it is applied by a relaunch (`POST /api/update/restart`). Runs **inline** on the
single accept thread (like the Git/atelier routes). Errors: `409 no_update`,
`409 already_installing`, `409 busy` (a Turn is running — the Engine Runspace is in
use), `502 update_failed` (the DeskPilot install failed). On success:

```json
{
  "ok": true,
  "restartRequired": true,
  "includePrerelease": false,
  "engineReloaded": true,
  "engineVersion": "0.2.5",
  "modules": [
    { "name": "DeskPilot", "version": "0.3.0", "installed": true, "error": null },
    { "name": "ShellPilot", "version": "0.2.5", "installed": true, "error": null }
  ],
  "message": "Update installed. The Engine (ShellPilot) reloaded and is active now. Restart DeskPilot to finish applying the app update."
}
```

### `POST /api/update/restart`

Relaunches DeskPilot in a fresh process (which imports the updated DeskPilot and
ShellPilot, reusing the same data directory so Conversations carry over) and
signals the current process's accept loop to stop (`Restart-DpHost`). This is the
only safe way to apply the DeskPilot host update — the running module cannot
hot-swap its own executing code. The new instance opens its own browser tab on a
fresh port, so the calling tab loses its connection. Errors: `409 busy` (a Turn is
running), `502 restart_failed`. On success: `{ "ok": true, "message": "DeskPilot is
restarting. A new window will open; you can close this tab." }`.

## Memory

Persistent, cross-Conversation memory injected into every Turn's system prompt.
Two stores: the **User Profile** (the manual `preferences` Setting) and the
**Agent Memory** (an agent-curated store persisted to `agent-memory.json`). Both
are bounded (`Get-DpMemoryLimits`: User Profile 8,000 chars, Agent Memory 12,000
chars) and fenced in the system prompt as reference-not-instructions
(`New-DpTurnParameter`).

### `GET /api/memory`

Returns both stores with their character counts and caps, plus whether autonomous
learning is on:

```json
{
  "userProfile": { "text": "...", "chars": 42, "cap": 8000 },
  "agentMemory": { "text": "...", "chars": 310, "cap": 12000, "updatedUtc": "2026-07-07T20:00:00Z" },
  "learning": true
}
```

### `PUT /api/memory`

Body: `{ "userProfile"?: string|null, "agentMemory"?: string|null }` — either or
both. The User Profile is validated and persisted through `Merge-DpSettings` (the
`preferences` Setting); the Agent Memory is trimmed and written to
`agent-memory.json`. `400 too_long` if a store exceeds its cap. Returns the same
shape as `GET /api/memory`.

### `POST /api/memory/learn`

Body: `{ "conversationId": string }`. Runs a **pure-reasoning Turn** with all Tools
disabled (like auto-title / compaction) that folds durable facts from the
Conversation's recent messages into the Agent Memory via `New-DpMemoryPrompt` +
`ConvertFrom-DpMemoryResult`, capped to the Agent Memory limit. Best-effort: a
failed extraction leaves the memory unchanged. Errors:
`400 missing_conversation`, `404 not_found`, `409 busy` (a Turn is running),
`400 too_short` (too few messages). Returns the `GET /api/memory` shape plus
`"changed": <bool>`.

The SPA also calls this route automatically (throttled by assistant-turn count)
after a Turn when the `memoryLearning` Setting is on, mirroring auto-titling.

## Uploads

### `POST /api/uploads`

Content-Type: `multipart/form-data`. Each `file` part is written under a
collision-safe filename: to the active Workspace Folder when a Project is
selected, otherwise to an `uploads` folder in the per-user data directory (so an
upload never requires a registered Project). Returns the saved files:

```json
{
  "files": [
    { "name": "report.pdf", "savedAs": "report.pdf",
      "path": "C:/Users/me/Documents/DeskPilot/report.pdf",
      "bytes": 18342, "contentType": "application/pdf" }
  ]
}
```

Returns `413` when an individual part exceeds 25 MiB.

## Static assets

`GET /` → `index.html`; `GET /assets/*` → CSS/JS/fonts/icons. Unknown non-API
paths fall back to `index.html` (SPA routing).

## Conventions

- Times are ISO-8601 UTC.
- Ids are short opaque strings (`c_*` Conversation, `m_*` Message).
- SSE frames are `event: <name>\ndata: <json>\n\n`; a `: heartbeat` comment line
  is sent every ~15 s to keep the connection alive.
