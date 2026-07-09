# Active Context

## Current focus

**Added an opt-in CopilotAtelier setup to the Agent menu — SHIPPED on
`ai/atelier-setup` (2026-07-09, local-only; NOT merged, NOT pushed).** The user
asked for a way to set up [CopilotAtelier](https://github.com/raandree/CopilotAtelier)
from the Agent picker (the "No agent" popover in the composer). Since it is a
repository, not an installable module, DeskPilot now downloads it and runs its
`Setup-CopilotSettings.ps1` — but only after explicit consent (the user's
requirement: "ask for permission, not one-click"). **Design:** the Agent menu
(`buildAgentMenu`) always shows a **Set up CopilotAtelier…** action (below the
agents/divider), which opens a dedicated consent modal (`#atelier-modal`) that
spells out exactly what the script changes — the `~/.copilot/{agents,
instructions,skills,prompts}` NTFS junctions, VS Code `settings.json`/
`keybindings.json`, and the `COPILOT_ALLOW_ALL` user env var — before anything is
fetched or run. On confirm it POSTs `/api/atelier/setup`. **Backend:** two new
Private helpers — `Get-DpAtelierSource` (downloads the `main` zipball over HTTPS
from the fixed first-party URL via `Invoke-WebRequest`, extracts it, and
normalises the folder to the canonical `CopilotAtelier` name the setup script
derives its OneDrive target from; under `<dataDir>/atelier`; never throws) and
`Invoke-DpAtelierSetup` (locates `Setup-CopilotSettings.ps1` and, **on Windows**,
launches it in a **visible `pwsh` console the user drives** so the script's own
`Read-Host` prompts — OneDrive account choice, replacing a non-empty folder —
work and DeskPilot never answers them; on non-Windows it returns the path for a
manual run). The launcher and `$IsWindows` are injectable params (`-Launcher`,
`-IsWindowsPlatform`) so the orchestration is unit-tested without a real process
or network. Route `POST /api/atelier/setup` (token-gated like all `/api/*`) →
`atelierSetup` handler. **Frontend:** `openAtelierSetup`/`renderAtelierConsent`/
`runAtelierSetup` + a Refresh-agents step that re-loads the agent list and Atelier
health once setup finishes. **Security:** downloading+executing remote code is the
requested function; mitigated by the fixed first-party HTTPS URL (no
user-supplied URL → no SSRF/injection), the explicit consent gate, the
user-driven console, and Windows-scoping the auto-run (specs/050 T12).
**Verified: full Sampler build+test 364/364, 0 failed (16 tasks, 0 errors, 0
warnings); both new helpers AST-parse + PSSA clean; `app.js` ESM check OK; web
files language-service clean.** Not yet browser-smoke-tested. Docs: CHANGELOG
(Added), specs 010 (FR-X7) / 040 (Agent dropdown) / 050 (T12), glossary
(CopilotAtelier row + note).

## Prior focus — clean-machine sign-in fix

**Fixed clean-machine sign-in — the Engine token-file rename broke DeskPilot's
auth detection (2026-07-09; fix `458e250` now MERGED into `main` via merge commit
`734e646` — clean, no conflicts; `main` is 2 ahead of `origin/main`, local-only,
NOT pushed).** A user reported that authenticating in DeskPilot on a new clean
machine never completed (they had installed ShellPilot `0.2.1-preview0001`
first). Root cause: ShellPilot renamed its cached OAuth token file from
`.copilot-demo-token` to `.shellpilot-token` in 0.2.1, but `Initialize-DpEngine`
hardcoded the old name into `Engine.TokenPath`. On a clean machine — the ONLY
path that runs the real device-code flow, since a machine with a stale token
short-circuits in `Invoke-DpAuthFlow` as "already signed in" — the flow
completed and the Engine wrote `~/.shellpilot-token`, but the post-auth
`Test-Path Engine.TokenPath` (and `/api/health`, `/api/auth/status`) checked
`~/.copilot-demo-token`, found nothing, and returned `authenticated:false`, so
the SPA showed *"Sign-in did not complete. Try again."* on every attempt — an
inescapable loop. Fix (single point, `Initialize-DpEngine`): after importing the
Engine, probe its own `$script:DefaultTokenPath` in the module's scope
(`& (Get-Module ShellPilot) { $script:DefaultTokenPath }`) and use that for
`Engine.TokenPath`; fall back to `~/.shellpilot-token` (preferring an existing
legacy `~/.copilot-demo-token`) only when the probe is unavailable. DeskPilot is
now version-agnostic to the Engine's token filename — it always checks the file
the Engine actually writes — and the one change fixes all four `Engine.TokenPath`
consumers. **Verified: the probe was reproduced live against ShellPilot 0.2.0 on
disk (returns `...\.copilot-demo-token`, 0.2.0's default — proving it reads
whatever the imported Engine uses; 0.2.1 returns `.shellpilot-token`);
`Initialize-DpEngine.ps1` AST parse 0 errors + PSScriptAnalyzer clean; full Unit
suite 207/207, `Test-DpAuthError`/`Test-DpTransientEngineError` 19/19.** The
attached video could not be decoded here; the diagnosis was reconstructed from
the DeskPilot auth path plus the current ShellPilot source (its CHANGELOG rename
note). Docs: CHANGELOG (Fixed), techContext auth fact, specs/050 T4; the two
classifier test sample strings were refreshed to the current filename.

## Prior focus — Gallery publish (web UI bundled)

**Publish DeskPilot to the PowerShell Gallery with the web UI bundled - SHIPPED
on `ai/gallery-web-bundle` (2026-07-08, local-only; NOT merged, NOT pushed, NOT
published).** After a fresh grill-me interview (signed off), implemented the
Design Concept. `git mv web -> source/web` + `build.yaml` `CopyPaths: ['web']`
bundle the SPA into the built module. `Start-DeskPilot` dropped its public
`-WebRoot` and resolves `$PSScriptRoot/web` internally, with a
`DESKPILOT_WEB_ROOT` env override the dev launcher + tests set to `source/web`
for hot-reload; it fails fast before binding if the bundle or index.html is
missing. The version is derived from the manifest (no more hardcoded `0.1.0`).
Manifest fixed for the Gallery (Author `Raimund Andree`, ProjectUri
raandree/DeskPilot, IconUri -> logo, Description/ReleaseNotes/Tags). ShellPilot
is NOT a hard manifest dependency (that broke import when it was absent); it
stays resolved at runtime by `Resolve-DpEngineModule`, and build
`RequiredModules.psd1` tracks `ShellPilot = 'latest'`. Added
MIT `LICENSE`, Gallery/CI README badges + a Gallery-install quick-start, and a
fail-silent, non-blocking launch-time update check (`Get-DpUpdateNotice`, +5
tests, surfaced via a background job on an idle accept-loop iteration). New
`tests/Unit/WebAssets.Tests.ps1`: bundle presence, Linux case-sensitivity guard,
and a public-Gallery secret scan - all green, so the web/ secret audit is clean.
Docs: CHANGELOG, techContext, specs 020/040. **Verified: full Sampler build+test
green twice - 17 tasks, 0 errors, 0 warnings; built `0.2.0-ai`; WebAssets 4/4,
Start-DeskPilot 3/3, 0 failed, 0 NotRun.** A first build was falsely green because
the WebAssets guards used `-ForEach`+`BeforeDiscovery` and failed discovery (2
NotRun, which Pester does not count as failures); rewrote both as run-time loops
inside one `It` before the clean re-run. Scope was publishable-but-NOT-published:
no publish, no publish secrets set (adding the `GalleryApiToken`/`GitHubToken`
repository secrets is the real go-live gate and stays your action), no push/merge.

## Prior focus - streaming smoothness (items 3 + 4)

**Streaming smoothness (items 3 + 4) — SHIPPED + MERGED to `main` (2026-07-08,
local-only, not pushed).** From the performance analysis (below), implemented the two
DeskPilot-only, low-risk fixes on `ai/stream-smoothness`, then fast-forwarded
`aa95a5d..1e032ac` into `main` after a clean 348/348 build (a first re-verify build hit a
transient file lock on the built `DeskPilot.psm1` from a lingering session that held the
imported module; cleared by deleting the built-module folder and rebuilding — environmental,
not code). **Item 3:** `Invoke-DpTurn`'s Information-stream drain
poll dropped **40 ms → 10 ms**, and the emit path now **coalesces** consecutive same-kind
text records (`delta`/`reasoning`) into one buffered SSE frame per drain (new `$flush`
scriptblock + `pendingEvent`/`pendingText` on `$turnState`) instead of a JSON-encode +
auto-flushed socket write per token; a `tasks` frame or kind change flushes first so
ordering is exact, and `emitted` counts buffered records so the transient-error retry
still never duplicates answer text. Heartbeat kept ~10 s (1000 × 10 ms). **Item 4:** the
explorer's 5 s auto-refresh `tick` returns early while `state.streaming`, so the
single-threaded Host Server never runs a directory + Git scan inline in the streaming
loop (the turn's `finally` still refreshes once on end). **Items 1 + 2 (ShellPilot: cache
the session token; reuse a pooled `HttpClient`) were handed off as a copy-paste prompt**
for the ShellPilot repo — Engine is sacrosanct, not changed here. **Verified: full Sampler
build+test 348/348, 0 failed (16 tasks, 0 errors, 0 warnings); AST 0 errors; `app.js` ESM
check exit 0.** PSSA on `Invoke-DpTurn.ps1` shows one *pre-existing*
`PSUseBOMForUnicodeEncodedFile` warning from the `'…'` in the title-truncation fallback
(not my code) — left unchanged. Not yet browser-smoke-tested.

## Prior focus — performance analysis (DeskPilot + ShellPilot) vs GHCP VS Code (2026-07-08)

**Performance analysis (DeskPilot + ShellPilot) vs the GHCP VS Code extension —
RESEARCH ONLY, no code changed (2026-07-08).** The user reported DeskPilot "feels
way slower" than the VS Code Copilot extension and asked for root causes across both
repos. Findings, ranked. **Total-time (throughput) causes:** (1) ShellPilot
`Invoke-ShpStreamRequest` / `Invoke-CopilotTurn` create a **new `HttpClient` per API
call** and dispose it, so every tool-loop iteration pays a fresh TCP+TLS handshake to
the Copilot endpoint (no connection pooling / HTTP-2 reuse) — the biggest hit on
multi-step tasks; VS Code keeps one warm pooled connection. (2) ShellPilot
`Invoke-Shp` calls **`Get-ShpSessionToken` on every Turn** (an extra HTTPS round-trip
to `api.github.com/copilot_internal/v2/token` before the first model byte) although
the token carries `expires_at` and could be cached until near expiry. (3) Full
`-History` replay every Turn (DeskPilot design) grows the prompt with conversation
length; auto-compaction mitigates. **Perceived-smoothness causes (DeskPilot side):**
(4) `Invoke-DpTurn` drains the Engine Information stream on a **40 ms `Start-Sleep`
poll** and does per-token regex classify (`Get-DpStreamFrame`) + `ConvertTo-Json`
(`ConvertTo-DpSseFrame`) + auto-flushed socket write on the one thread, so streaming
arrives in chunky 40 ms bursts rather than smoothly. (5) The **single-threaded accept
loop** services background requests inline via `Invoke-DpPendingRequest` inside that
same poll, so the 5 s explorer/git auto-refresh (`setInterval(tick, 5000)`) stalls the
token stream while a directory/git scan runs. **Minor:** `[powershell]::Create()` per
Turn; `Connection: close` (no local keep-alive); 50 ms accept idle poll. Recommended
high-impact/low-risk fixes: cache the session token in ShellPilot until ~60 s before
`expires_at`; reuse one pooled `HttpClient`/`SocketsHttpHandler`; drop the DeskPilot
drain sleep to ~5–10 ms (or block on `DataAdded`) and coalesce delta frames. No files
changed; offered to implement.

## Prior focus — streamed Thinking line breaks (FIXED + MERGED 2026-07-08)

**Thinking output line breaks — FIXED + MERGED to `main` (2026-07-08, local-only,
not pushed).** The user reported that the model's streamed *Thinking*
sometimes ran together with no line breaks (e.g. "…before I
consolidate.GitHub code search needs auth."), making it unreadable. Root cause was
entirely on the DeskPilot side: the Engine emits each reasoning/trace line as one
`Write-Host` record whose `HostInformationMessage.Message` carries the text WITHOUT
the trailing newline — the line break lives in the separate `NoNewLine` flag
(`$false` for a complete line, `$true` for a `-NoNewline` streamed token).
`Get-DpStreamFrame` streamed each record's cleaned text verbatim, and the SPA
concatenates the `reasoning`/`delta` frames, so distinct complete lines glued into
one run-on wall. Fix (single point, `Get-DpStreamFrame`): capture
`$completeLine = ($messageData.NoNewLine -eq $false)` and re-attach a `` `n `` to the
emitted frame text for complete-line writes only. Streamed tokens (`$true`) and
unspecified (`$null`, i.e. synthetic test records) are left untouched, so the answer
token stream is unchanged and the existing tests still pass. The SSE path is safe:
object payloads are JSON-encoded (`ConvertTo-Json -Compress`), so the real newline
becomes an escaped `\n` sequence that survives `ConvertTo-DpSseFrame`'s newline
flatten and is restored by the client's `JSON.parse` — the same mechanism the final
answer Markdown already relies on. No frontend change needed (the Thinking pane is
already `white-space: pre-wrap`; the answer is Markdown-rendered). +4 unit tests.
CHANGELOG `[Unreleased] → Fixed`. **Verified: `Get-DpStreamFrame` describe 10/10;
full Unit helpers file 336/336, 0 failed; AST parse 0 errors; PSScriptAnalyzer clean
on the changed helper.**

## Prior focus — Settings drawer reorganised into tabs — SHIPPED + MERGED to `main` (2026-07-08, local-only, not pushed)

The user flagged that the Settings drawer had grown long (one scrollbar,
~23 stacked fields) and asked for tabs or another organiser. Grouped the fields into
six tabs shown as a sticky, wrapping pill strip at the top of the drawer:
**General** (model, reasoning effort, show thinking, task tracking, max iterations,
theme), **Permissions**, **Projects** (projects + reference files),
**Customizations** (Skill/Instruction/Prompt roots, Agents folder, Atelier health),
**Memory & context** (User profile, Agent memory, learn toggle, auto-compaction), and
**Engine & data** (spend warning, Engine status, back up & restore).

Key decision: **every panel stays in the DOM; only the active one is shown.** So all
the existing field handlers (which bind by element id) keep working untouched — the
change is purely presentational. New `wireSettingsTabs(body)` in `app.js` toggles the
active button/panel, maintains `aria-selected` + roving `tabIndex`, and implements the
WAI-ARIA tablist keyboard pattern (Left/Right/Home/End). CSS: `.settings-tabs`
(sticky, `flex-wrap`, negative margins for full-bleed + `top:-16px` to cancel the
body's top padding), `.settings-tab-btn` (pills like `.range-btn`), `.settings-tab`
(shown only when `.active`). Frontend-only + specs/040 §6 + CHANGELOG. **Verified:
`app.js` ESM check OK (exit 0); app.js + styles.css report 0 errors.** Not yet
manually smoke-tested in a browser.

## Prior focus — persistent memory (User Profile + Agent Memory), SHIPPED + MERGED to `main` (2026-07-08, local-only, not pushed)

**Persistent memory (User Profile + Agent Memory) — SHIPPED + MERGED to `main`
(2026-07-08, local-only, not pushed).**
The user approved building the Hermes-style memory researched earlier, "a bit
bigger, my call on size." Delivered a persistent, cross-Conversation memory injected
into every Turn's system prompt (fenced as reference-not-instructions), in two
parts: **User Profile** (the manual `preferences` block, reframed; 8,000 chars) and
a new agent-curated **Agent Memory** (12,000 chars, its own `agent-memory.json`
store). Combined worst case ~20,000 chars / ~5,000 tokens per Turn — ~5× Hermes's
~3,600, still <5% of a 128k window (my sizing rationale, in `Get-DpMemoryLimits`).

Curation is two-way: **autonomous** (`maybeLearnMemory` in `_runTurn`'s finally,
throttled to every 5th assistant Turn, best-effort, re-entrancy-guarded, silent on
400/409, toasts only when it changes something; default on via `memoryLearning`) and
**manual** (an "Update from this conversation" button + full view/edit/clear in
Settings → Memory). The learn pass is a pure-reasoning Turn (Tools off via
`Invoke-DpEngineCommand`, like auto-title/compaction); no Engine change.

Backend: 6 new Private helpers — `Get-DpMemoryLimits` (caps, one source of truth),
`Import-DpMemoryStore`/`Save-DpMemoryStore` (atomic JSON; `ConvertTo-DpIsoString` on
load to survive JSON date coercion — a bug the first build caught),
`New-DpMemoryPrompt` (declarative-facts rule, NO_CHANGE sentinel, no-secrets),
`ConvertFrom-DpMemoryResult` (clean fences/labels, NO_CHANGE→'', cap on a line
boundary), `Get-DpMemoryPayload`. `New-DpTurnParameter` gained `-AgentMemory` (fenced
block after preferences); `Invoke-DpTurn` reads `$script:DeskPilot.Memory.text` and
passes it. New `memoryLearning` Setting (default on). Store loaded into state at
startup. Routes `GET`/`PUT /api/memory`, `POST /api/memory/learn`
(404/409/`400 too_short`/`missing_conversation`; returns `changed`).

Frontend (`app.js`): Settings "About you" → **User profile**; new **Agent memory**
field (textarea + live char/budget count + updated time + Update button) + a **learn
automatically** toggle; `renderMemMeta` GET/PUT/learn wiring; `maybeLearnMemory`. CSS
`.mem-row`/`.mem-learn-btn`. +17 unit tests. Specs 010 (FR-M7 reframe, FR-M12/M13,
FR-S1) / 030 (Memory section) / 040 (Settings memory) / 050 (T11) / 060 (Phase 2.8) +
glossary (Memory / User Profile / Agent Memory + **Memory vs. the dev `.memory-bank/`**
note). CHANGELOG. **Verified: full Sampler build+test 344/344, 0 failed (16 tasks, 0
errors, 0 warnings); `app.js` ESM check OK.**

**Also on this branch (a separate commit): hardened `Get-DpAgentList`** to suppress a
`Test-Path` access-denied error on an inaccessible agents root (returns `@()` per its
contract). This surfaced as an environmental failure on this machine — a restricted
`X:` drive throws Access Denied under the build's `ErrorActionPreference=Stop`;
pre-existing, not caused by the memory feature. The fix also makes the build green here.

## Next steps

1. **Review + merge `ai/gallery-web-bundle`** (Gallery-publishable, web UI
   bundled; local-only, not pushed/merged/published - your call).
2. **Go live when ready (Phase D):** add the `GalleryApiToken` + `GitHubToken`
   repository secrets in GitHub (Settings -> Secrets and variables -> Actions ->
   Secrets). There is NO `PUBLISH_ENABLED` variable - the current ci.yml mirrors
   ShellPilot and self-guards on the secrets' presence. A push to `main` then
   publishes a `-preview` prerelease and a `v*` tag a stable release. Validate
   with a first prerelease. Confirm the Author string + `IconUri` before a real
   publish.
3. **Manual browser smoke of the Settings tabs:** open Settings; confirm the six
   tabs switch (click + Left/Right/Home/End), each field still saves (model, a
   permission toggle, add a project, a folder path, memory edit/learn, a compaction
   value, theme), the pill strip stays pinned under the drawer head while scrolling a
   tall tab, and it wraps to two rows in a narrow window.
2. **Manual + live smoke of persistent memory (now on `main`):** run a couple of
   Conversations, confirm the Agent memory fills in (auto every 5th assistant Turn +
   the manual button), confirm injection (the agent recalls a stated fact in a fresh
   Conversation), edit/clear it in Settings, and toggle learning off.
3. **Persistent memory merged to `main`** (2026-07-08, fast-forward
   `862bce2..a748b00`, local-only) — done. Push is deferred and not performed unless
   explicitly requested.

## Prior focus — Memory & context batch (Hermes-inspired), SHIPPED + MERGED to `main` (2026-07-08, local-only, not pushed)

The user shared screenshots of a similar local agent tool ("Hermes" — Usage,
System, and Memory & Context screens) and asked to migrate useful ideas: update
the specs and implement to done while they were away. Delivered two well-fitting
features and documented the deferred ones.

**Feature 1 — Automatic conversation compaction (the headline).** Builds directly
on the just-shipped manual Compact + Context Window gauge. After a Turn, when the
new `autoCompaction` Setting is on and the measured occupancy
(`promptTokens ÷ maxContextWindowTokens`) reaches `compactionThreshold`, the SPA
fires the existing `POST /compact` route itself — mirroring `maybeAutoTitle`. New
`maybeAutoCompact()` runs in `_runTurn`'s finally (after `maybeAutoTitle`), gated on
occupancy ≥ threshold, re-entrancy-guarded (`state.autoCompacting`), treats
`400 too_short` as a silent no-op, and toasts freed tokens on success. Three new
Settings in `Get-DpDefaultSettings` + validated in `Merge-DpSettings`:
`autoCompaction` (bool, default **on**), `compactionThreshold` (0.5–0.95, default
0.8, rounded 2 dp), `compactionKeepRecent` (2–100, default 4). The compact route now
reads `keepCount` from `compactionKeepRecent` (clamped), so one knob drives manual +
auto. Settings drawer gained a **Memory & context** section (toggle + threshold% +
keep-recent); the Session Info popover shows a one-line "Auto-compaction is on (at
N% full)" indicator. Mirrors Hermes's Auto-Compression / Threshold / Protected
Recent Messages. Default-on is defensible: every firing is visible (toast + meter +
compacted marker) and it usually *saves* credits over a long Conversation, honouring
"cost is honest" / "surface, don't hide".

**Feature 2 — Usage panel enhancements.** Frontend-only (data already tracked):
`usageRows` now shows **Tokens in** (`promptTokens`) / **Tokens out**
(`completionTokens`) alongside the totals; a new **Top models (this session)** list
(`renderTopModels`, from the existing `byModel`); and a **30d** range button
(7d/14d/30d). `Get-DpUsagePayload` daily window bumped 30→60 (the full retention) so
the 30d chart always has coverage. Mirrors Hermes's Tokens IN/OUT + Top Models +
30d.

**Deferred (documented in specs/060 Phase 2.7 + deferred list):** Hermes's **System
screen** (live server logs + in-app update/restart) — the status/version parts
overlap Settings→Engine + `/api/health`; the new parts need a logging ring buffer
threaded through the Host Server + a self-update path (a larger, separate track).
**Persistent agent memory** — Preferences already cover the User-Profile half.
**Top Skills** — the Engine doesn't report which Skill ran (Engine-sacrosanct).

Backend: `Get-DpDefaultSettings` (+3 keys), `Merge-DpSettings` (+3 validated cases),
compact route keepCount from settings, `Get-DpUsagePayload` daily 60. Frontend
(`app.js`): `maybeAutoCompact`, settings section + wiring, session-popover indicator,
`usageRows` +2 rows, `renderTopModels`, `populateUsagePopover` call; `index.html`
top-models block + 30d button; `styles.css` `.usage-models*`. +6 unit tests. Specs
010 (FR-C19, FR-U5, FR-S1) / 030 (compact keepCount + auto-compaction note, settings
validation, usage daily/tokens note) / 040 (Session Info indicator, Memory & context
settings, Usage popover) / 060 (Phase 2.7 + deferred). Glossary: Auto-compaction row
+ "Auto-compaction vs. Compact" note. CHANGELOG updated. **Verified: full Sampler
build+test 327/327, 0 failed (16 tasks, 0 errors, 0 warnings); `app.js` ESM check OK
(`.mjs`).** The ESM check caught a dropped `stopTurn` declaration during editing —
fixed before the green run.

   this session. DeskPilot's `preferences` Setting already ≈ USER.md (manual); the
   gap is an agent-writable MEMORY.md + a memory tool + auto-injection. Proposed,
   awaiting go-ahead.

## Prior focus — Session Info popover + Compact conversation (SHIPPED + MERGED to `main`, 2026-07-07)

The user asked for a menu like GHCP's Session Info screenshot on a Conversation.

## Prior focus — extended conversation ⋯ menu (SHIPPED + MERGED to `main`, 2026-07-07)

**Extended the per-Conversation ⋯ menu (8-feature batch) — SHIPPED + MERGED to
`main` (2026-07-07, local-only, not pushed).**
The user asked to extend the conversation menu like VS Code's Chat Sessions menu
plus researched extras, and reviewed a tiered proposal before work. Approved set:
Open in new window (A1), Mark unread / Mark all read + badge (A2), keyboard
shortcuts (A4), grouped menu with separators (A5), Duplicate (B1), Copy transcript
(B4), Details popover (B6), Colour label (C4). **Deletion is deliberately
unchanged** (the user said so mid-turn): the hover ✕ and its instant delete stay
as-is; Delete was NOT added to the menu.

Backend: new `unread` (bool) + `color` (nullable palette name) Conversation fields
through `New-DpConversation` / `Save-DpConversationStore` / `Import-DpConversationStore`;
`patchConversation` accepts `unread`/`color` (colour validated → `400 bad_color`;
organisational flags don't bump `updatedUtc`); `list`/`search` summaries carry both;
new `Copy-DpConversation` helper (JSON-round-trip deep copy, new id, `Copy of `
prefix, flags reset, `titleLocked`); new routes `POST /api/conversations/{id}/duplicate`
(201) and `POST /api/conversations/read-all` (registered before `/{id}`).

Frontend (`app.js`): grouped menu (Open / Organise / Manage with `menu-divider`s +
a colour-swatch row), `openConversationInNewWindow` (deep link `/?c=` handled in
`enterApp`), `duplicateConversation`, `toggleUnread` + `markAllConversationsRead` +
`updateMarkAllReadButton` (a "Mark N as read" button in index.html), unread dot +
bold title + colour dot in `renderConversationList`/`renderSearchResults`,
`handleConvItemKey` (Enter/F2/Delete=archive on a focused row), `setConversationColor`,
`copyTranscript` + extracted `buildTranscript` (reused by export),
`showConversationDetails`. Unread clears on open in `selectConversation`. Palette
names mirror the backend allow-list. CSS + index.html button added.

+6 unit tests. Glossary rows (Unread, Duplicate, Colour) + notes. Specs 010
(FR-C17) / 030 / 040 updated. Verified: full Sampler build+test **305/305, 0
failed** (16 tasks, 0 errors, 0 warnings); `app.js` ESM check OK (`.mjs`).

**Follow-up (same branch):** the **Details** popover now also shows the
**accumulated Usage** — cost, credits, and tokens summed across the Conversation's
Messages (new `sumConversationUsage` in `app.js`; `showConversationDetails` is now
async and fetches the full Conversation on open to sum per-Message `usage`). No
backend change; formatting matches the Usage popover. `app.js` ESM check OK; the
sum logic is node-verified.

## Prior focus — automatic conversation titles (SHIPPED + MERGED to `main`, 2026-07-07)

A brand-new Conversation is auto-titled from its first prompt via a best-effort
`POST /api/conversations/{id}/title` (pure-reasoning Turn, Tools off;
`New-DpTitlePrompt` + `ConvertFrom-DpTitleResult`); a manual rename sets
`titleLocked` so auto-titling never overwrites it. The instant 60-char truncation
stays as the fallback.

## Next steps

1. **Manual + live smoke of Session Info / Compact (`ai/session-info-compact`, not
   yet merged):** open a Conversation with a few Turns; confirm the top-bar context
   meter appears and the Session Info popover shows cost + a sensible context %
   gauge (measured `promptTokens` ÷ model window) + the estimated Messages/System
   breakdown; run **Compact conversation** and confirm the toast reports freed
   tokens, the visible transcript is unchanged, and the next Turn's measured context
   is smaller. Live-exercise `POST /compact` (needs the Engine authenticated):
   `too_short` on a fresh Conversation, a real summarise on a long one, `409` while a
   Turn runs. (The branch is already fast-forwarded into `main`, local-only.)
2. **Manual browser smoke of the conversation ⋯ menu (already merged into `main`):**
   open the ⋯ menu, try each action — open-in-new-window (confirm the deep link
   `/?c=` opens the right Conversation), Duplicate, mark unread + "Mark N as read",
   set/clear a Colour, Copy transcript, Details; and the row keyboard shortcuts
   (Enter/F2/Delete).
3. **Live HTTP smoke of the merge routes** (before merging the Merge Wizard to
   main): exercise /api/git/branches, /merge/preview, a real merge, a conflict →
   /merge/plan → /merge/apply, and /cleanup (local-only; the plan route needs the
   Engine authenticated).
4. **Manual browser smoke** of the Merge Wizard (badges, tooltips, each step).
5. **Clone Wizard (spec 080):** one New Project Wizard (clone-vs-local first
   screen); `Invoke-DpGitClone`; `POST /api/projects/clone`; reuse the folder
   picker; SSH + ambient credentials only; auto-select the new Project.
6. Then resume the parked publish/Sampler work (Phase B/D) if desired.

## Prior focus — "Working…" spinner froze under reduce-motion (FIXED + MERGED 2026-07-07)

The streaming donut sat frozen for users with OS animations off (a blanket
`@media (prefers-reduced-motion: reduce) { * { animation: none } }` in
`styles.css` killed its rotation). CSS-only fix: a targeted `.spinner` override
keeps it smoothly rotating (`spin 1s linear infinite`) under reduced motion, plus
a legibility bump. Fast-forwarded `0667920..4896066` into `main` (local-only);
`ai/working-spinner-motion` kept.

## Prior focus — Transient 403 on the Copilot session-token exchange (FIXED + MERGED 2026-07-07)

**Transient 403 on the Copilot session-token exchange failed the whole Turn —
FIXED + MERGED to `main` (2026-07-07).**
ShellPilot exchanges the cached GitHub token for a short-lived Copilot session
token at the start of every Turn; that endpoint intermittently returns 403
(Forbidden), so `Invoke-Shp` threw, `EndInvoke` rethrew, and the Turn failed with
a raw *"Session token exchange failed … 403"* — the user had to stop and resend
(which worked, because a retry of the exchange succeeds). Fix: a bounded retry of
the Engine call in `Invoke-DpTurn` for transient PRE-STREAM failures, so these
blips are invisible. All four fixes from `ai/stop-button-fix` are now
fast-forwarded into `main` (`ac71cec..c89c0c7`, local-only, not pushed); the
Clone Wizard (specs/080) is the next feature.

## Just completed (this work, on ai/stop-button-fix)

- **New `Test-DpTransientEngineError`** (`source/Private`): flags transient Engine
  failures worth retrying (403/408/429/5xx, forbidden, timeouts, dropped
  connections, unable-to-connect) by walking the inner-exception chain —
  deliberately NOT 401/Unauthorized, so a genuine expired sign-in is surfaced for
  re-auth, never retried.
- **`Invoke-DpTurn` retry**: the Engine invocation now runs in a bounded loop
  (max 3 attempts, 400 ms × attempt back-off). It retries ONLY when the failure is
  transient AND nothing has streamed yet (`$turnState.emitted -eq 0`, a new frame
  counter incremented in `$emit`), so answer text is never duplicated; a Stop
  during a back-off ends the Turn cleanly.
- **Tests:** +10 `Test-DpTransientEngineError` unit tests (403/429/503/timeout/
  dropped-connection/inner-exception → true; 401 + missing-token + unrelated +
  null → false).

Verified: full test suite **282/282, 0 failed** (16 tasks, 0 errors, 0 warnings).
Manual smoke: reproduce a 403 (or hit the flaky endpoint) and confirm the Turn now
streams normally instead of failing — no stop-and-resend needed.

## Recently on this branch — expired sign-in re-auth (FIXED 2026-07-07)

`authenticated` reflected the token *file* existing, not its validity, so an
expired token dead-ended at "(sign in to load models)". Now `/api/models` returns
`401 auth_required` (`Test-DpAuthError`) and the UI auto-opens the sign-in overlay
in an "expired" mode that forces a fresh device flow (`Invoke-DpAuthFlow -Force`
→ `Initialize-Shp -Force`). +9 unit tests. Specs 030.

## Also on this branch — conversation menu sizing (FIXED 2026-07-07)

The per-conversation “…” action menu (`popover popover-menu conv-action-menu`) was
hugely oversized: JS positions it with an inline `top`, but it inherited the base
`.popover` `width: min(420px,92vw)` and `bottom: 92px`, so it was ~420px wide and
(top + bottom both set) stretched down the viewport. CSS-only fix on
`.conv-action-menu`: `width: max-content` (+ `min-width:160px`, `max-width`) and
`bottom: auto`. No JS change.

## Prior focus — Stop button did nothing (FIXED 2026-07-07, ai/stop-button-fix)

The single-threaded accept loop handled each request inline, so a running Turn
held the only thread and the Stop button's `POST /stop` waited in the TCP backlog
until the Turn had already finished. `Invoke-DpTurn`'s poll loop now pumps pending
connections each iteration (`Invoke-DpPendingRequest`, sharing the new
`Invoke-DpClient`; `$script:DeskPilot.Listener` registers the `TcpListener`), so a
concurrent `/stop` is serviced mid-Turn and aborts the Engine pipeline. +5 unit
tests. Specs 020/030. Same branch as the sign-in fix above (not yet merged).

## Prior focus — Reasoning-effort HTTP 400 (SHIPPED + MERGED 2026-07-07)

Reasoning effort is a single global Setting, but support is per-Model
(`claude-haiku-4.5` advertises none → Copilot rejects `reasoning_effort` with
HTTP 400). Fix (defence in depth): the Host Server caches the `/api/models`
capability list; `New-DpTurnParameter` forwards `-ReasoningEffort` only when the
effective Model advertises the chosen effort; the Settings effort menu is
model-aware. +5 unit tests. Fast-forwarded `a1df360..9c3c3e8` into `main`.

## Prior focus — No-project working-directory leak (SHIPPED + MERGED 2026-07-07)

`Invoke-DpTurn` only repositioned the long-lived Engine Runspace when a
`workspaceFolder` was set, so a no-Project Turn ran in whatever directory the
runspace was last left in — the folder DeskPilot was launched from (its own repo
checkout, which has a `.memory-bank/`), or a previously selected Project. New
helper `Get-DpEngineWorkingDir` (Workspace Folder when set, else
`<dataDir>/workspace`); `Invoke-DpTurn` sets the location on every Turn. +3 unit
tests. Fast-forwarded `4dc9e63..0d75a87` into `main` (local-only).

## Prior focus — Attach without a Project (SHIPPED 2026-07-07)

Removed the last place that forced a selected Project (attaching a file): uploads
fall back to `<dataDir>/uploads` via the new `Get-DpUploadDir` when no Project is
active. Backend `Invoke-DpRouteHandler` dropped its `no_workspace` guard; the
frontend passes absolute upload paths when there is no Workspace Folder. +3
`Get-DpUploadDir` tests. Fast-forwarded into `main` (`596da8b..e313da7`).

## Prior focus — Close Project (SHIPPED 2026-07-07)

Added a way to close (deselect) the active Project so DeskPilot returns to a
no-project state; previously you could only switch Projects or create a new one.
UI + specs only — the backend already supported a null `selectedProjectId`
(deriving a null `workspaceFolder`). New `closeProject()` (= `selectProject(null)`);
a **Close project** entry in the composer project popover (shown only when a
Project is active); a **Close** button on the selected row of the Settings
Projects manager. +1 `Merge-DpSettings` regression (close clears selection +
`workspaceFolder`, keeps the Project registered — distinct from removal).


## Prior focus — Branch Merge Wizard (SHIPPED 2026-06-12)

The Merge Wizard lets a non-expert merge a Branch into the Default Branch (main,
else master) from the explorer Git bar (per-branch merged/not-merged badges +
legend; a "Merge into <default>…" step wizard; an AI-proposed Merge Plan on
conflict, approved before any write; local cleanup; remote push+delete behind a
SEPARATE confirm; Undo). Backend + 8 routes + UI on `ai/merge-wizard`
(50b4ca5 foundation, c84f628 backend, 0612594 routes+UI). Remaining for that
track: a live HTTP smoke of the merge routes.

## Design decisions in force (Merge Wizard, signed off 2026-06-12)

- Merge target / "merged?" basis = the Default Branch (origin/HEAD, else main, else master).
- Conflicts: AI PROPOSES a Merge Plan (pure-reasoning Turn, Tools off); user approves; DeskPilot writes+commits. Binary = keep-ours/theirs.
- Strategy ff-else-merge-commit; autofix stash->ff->merge->pop; abort safely on a pull conflict.
- Cleanup auto local delete; remote push+delete behind a SEPARATE explicit confirm; ambient git credentials only.
- Badge fetches from origin first in the wizard (accuracy); the Git bar uses no-fetch (speed). Remote-failure keeps the local merge. Undo resets the default to the pre-merge sha (local only).

## Constraints in force

- Localhost-only bind + per-launch session token; single active Turn at a time
  (the merge/plan route guards on $state.TurnRunning, returns 409 if busy).
- Filesystem + Git endpoints confined to the selected Project's folder; git runs
  via Invoke-DpGitCommand (process, no shell). Remote push/delete is the only
  networked privileged action and requires a separate explicit per-action confirm.
- Canonical glossary terms only. README assets in assets/; in-app under web/assets/.

## Previous focus (publish/Sampler -- partially shipped)

Phase A (Sampler-ize) + Phase C (CI mirroring ShellPilot, deploy gated OFF) DONE.
Pending: Phase B (module-relative -WebRoot default, CopyPaths [web], manifest
metadata, MIT LICENSE, built-module smoke) and Phase D (go-live: pin stable
ShellPilot, iwr|iex bootstrap, add GalleryApiToken/GitHubToken secrets).
