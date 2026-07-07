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
    "messageCount": 4, "model": "claude-opus-4.8" }
] }
```

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
    { "id": "m_1", "role": "user", "text": "…", "createdUtc": "…" },
    { "id": "m_2", "role": "assistant", "text": "…",
      "reasoning": "… or null",
      "activity": { "filesRead": [], "filesWritten": [], "commandsRun": [],
                    "pagesFetched": [], "questionsAsked": [], "toolCalls": [] },
      "tasks": [
        { "id": 1, "title": "Read the Q2 notes", "status": "completed" },
        { "id": 2, "title": "Summarise key risks", "status": "in-progress" }
      ],
      "usage": { "promptTokens": 0, "completionTokens": 0, "totalTokens": 0,
                 "costUSD": 0.0, "credits": 0.0 },
      "model": "claude-opus-4.8", "durationMs": 0, "createdUtc": "…" }
  ]
}
```

### `DELETE /api/conversations/{id}`

Returns `204`. Also removes the Conversation from the persisted store.

### `PATCH /api/conversations/{id}`

Body: `{ "title"?: "…", "model"?: "…" }`. Returns the updated summary. Providing a
`title` also **locks** it (`titleLocked`), so auto-titling never overwrites a name
the user chose.

## Sending a Turn — **SSE**

### `POST /api/conversations/{id}/messages`

Body: `{ "prompt": "…" }`. Response is `text/event-stream`. Returns `409` if a
Turn is already running.

| event | data | when |
| --- | --- | --- |
| `start` | `{ "messageId": "m_3" }` | Turn accepted; assistant Message id allocated. |
| `delta` | `{ "text": "partial answer…" }` | each streamed answer chunk. |
| `activity` | `{ "kind": "tool", "name": "read_file", "detail": "./notes.md" }` | best-effort live Tool signal (optional in v1). |
| `tasks` | `{ "tasks": [ { "id": 1, "title": "…", "status": "in-progress" } ] }` | Task List update during the Turn; the **full** list is sent each time (idempotent replace, not a delta). At most one Task is `in-progress`. Status is one of `not-started`, `in-progress`, `completed`. |
| `done` | full assistant Message (same shape as in `GET conversation`) | Turn complete. The Message's `tasks` field is the authoritative final list (possibly empty). |
| `error` | `{ "message": "…" }` | Turn failed; history unchanged. |

The `tasks` event is emitted only when the `taskTracking` Setting is on. The
live frames originate from structured progress events on the Engine
Runspace's Information stream; see [020-architecture.md](020-architecture.md#in-turn-task-list).

Client stops a Turn with `POST /api/conversations/{id}/stop` → `202`. The single
accept thread services this request mid-Turn (the streaming loop pumps pending
connections), so the cancel flag is set while the Turn is still running; the Turn
then aborts the Engine pipeline and closes the stream with an `error` frame
(`{ "message": "Turn stopped." }`).

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
**daily** series (the last 30 UTC days of the persisted history) for the usage
graph. Credits are rounded to 4 decimals and cost to 6 to avoid floating-point
drift.

```json
{
  "session":  { "promptTokens": 0, "completionTokens": 0, "totalTokens": 0,
                "costUSD": 0.0, "credits": 0.0, "turns": 0 },
  "lifetime": { "promptTokens": 0, "completionTokens": 0, "totalTokens": 0,
                "costUSD": 0.0, "credits": 0.0, "turns": 0,
                "sinceUtc": "2026-06-01T00:00:00Z" },
  "byModel": [ { "model": "claude-opus-4.8", "totalTokens": 0,
                 "costUSD": 0.0, "credits": 0.0, "turns": 0 } ],
  "daily":   [ { "date": "2026-06-09", "credits": 0.31, "costUSD": 0.0031,
                 "totalTokens": 1200, "turns": 2 } ]
}
```

### `POST /api/usage/reset`

Resets a counter to zero. Body: `{ "scope": "lifetime" | "session" }`
(defaults to `lifetime`). Resetting `lifetime` also sets a new `sinceUtc` and
rewrites `lifetime-usage.json`. Returns the same payload as `GET /api/usage`.

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
