# Debugging Insights

Recurring issues and how they were resolved.

## The agent's shell is the *launcher's* shell, not the user's (2026-08-11)

**Symptom:** the agent and the user run the same command in the same folder and
get different answers, with nothing in the UI saying the environments differ.
Measured case: `Invoke-Pester` in `V:\Git\CopilotAtelier` reported 1 failure
under DeskPilot and 4 under VS Code Copilot.

**Root cause:** environment variables are **process**-global.
`[runspacefactory]::CreateRunspace()` (`Initialize-DpEngine.ps1:28`) supplies no
`InitialSessionState`, so the Engine Runspace simply reads the host process's
variables; `Invoke-RunCommandTool` then spawns its child `pwsh` with
`Start-Process` and no `-UseNewEnvironment`, so the child gets the same block
again. `build.ps1` prepends `output/RequiredModules` (`:449`) and `output/module`
(`:281`) to `$env:PSModulePath` **in the calling process**, and
`Start-DeskPilot.ps1` invokes `build.ps1` with the call operator on first run —
so DeskPilot's own pinned dependencies follow the agent into every repository.

**Reproduction (one command, only the module path varied):**

| `$env:PSModulePath` | Passed | Failed | Skipped |
|---|---:|---:|---:|
| target repo's own `output/RequiredModules` + `output/module` | 447 | 0 | 13 |
| DeskPilot's `output/RequiredModules` + `output/module` | 446 | 1 | 13 |
| Pester 6 imported by path, otherwise default | 443 | 4 | 13 |
| fully default (no Sampler paths) | 0 | 112 | 0 |

The 4 are the three `Changelog management` tests plus `Should import without
errors`; the 1 is that import test alone, because DeskPilot happens to vendor
`ChangelogManagement 3.1.0` too. A leaked `output/module` also **replaces** the
built-module directory, so the repo under test cannot import itself.

**Rule:** before trusting any module-resolving measurement the agent reports —
`Invoke-Pester`, `Invoke-Build`, `Invoke-ScriptAnalyzer`, any `Import-Module` —
have it print `$env:PSModulePath` and the resolved module path first. A bare
`Invoke-Pester` from a Sampler repo root is never the right gate; it also
recurses into `output/RequiredModules/Sampler/*/Templates` (measured 464/955/169).

**What does *not* drift:** `run_command` runs in a child process, so its
`$env:` writes and `Set-Location` never reach the runspace, the host, or the
next Turn (verified). The runspace loads no profile at all (`$PROFILE` is
`$null`, `$Host.Name` is `Default Host`), and `Set-DpEngineLocation` resets the
location every Turn. What *does* persist is
`[System.Environment]::CurrentDirectory`, which that helper sets process-wide.

**Installing the Engine properly does not fix this**, because the leaked modules
are DeskPilot's own *build* dependencies. Measured with ShellPilot 0.4.0 resolved
from `CurrentUser`: `ChangelogManagement`, `Pester` and `PSScriptAnalyzer` still
came from `V:\Git\DeskPilot\output\RequiredModules`.

**Which Engine actually runs.** `Resolve-DpEngineModule` sorts by `[Version]`,
which ignores the prerelease label, and `Sort-Object` is unstable without
`-Stable` — so once `RequiredModules.psd1` vendors the same version that is
installed, the two tie and the **prepended vendored copy wins** (5/5 observed).
A published Engine is therefore not necessarily the Engine in the runspace.

**Two constraints on any fix.** (1) An environment variable **cannot** be scoped
to a runspace: an `InitialSessionState.EnvironmentVariables` entry was visible in
the **host process** and in a grandchild process, so pinning `PSModulePath` is a
deliberate process-wide change, not isolation. (2) `Restart-DpHost` relaunches
with `Import-Module DeskPilot -Force` (`Restart-DpHost.ps1:41`) in a child that
inherits the pinned value — in a source checkout DeskPilot is only resolvable
because `build.ps1` put `output/module` on the path, so pinning breaks restart
unless the launcher imports by resolved manifest path.

## `run_command` silently strips double quotes (2026-08-11)

`Invoke-RunCommandTool` passes `@('-NoProfile', '-NonInteractive', '-Command',
$Command)` to `Start-Process`, and the native argument parser eats unescaped `"`.
Measured: a command assigning a double-quoted string reaches the child with the
quotes gone (exit 0, the words of the string parsed as separate tokens, stderr
"The term 'turn1' is not recognized"), and `git … --pretty=format:"%h %s"`
reaches git as two arguments. Single quotes survive.

**Rule:** the command in the transcript is not necessarily the command that ran.
Prefer single quotes in any command the agent is asked to run, and treat a
double-quoted command's output as unverified. The fix belongs in the Engine —
and the line is **unchanged** in the shipped 0.3.1, the installed 0.4.0, and
`V:\Git\ShellPilot\source\Private\Invoke-RunCommandTool.ps1:81`, so publishing
the current Engine ships the defect rather than fixing it.

## "IDE token expired" mid-Turn is the *session* token, not the sign-in (2026-08-11)

**Symptom:** a long Turn dies with `Copilot streaming request to
'https://api.enterprise.githubcopilot.com/chat/completions' failed with status
401: IDE token expired: unauthorized: token expired`, surfaced through
`EndInvoke`. The GitHub sign-in is plainly still valid, and resending the prompt
restarts from iteration 1 with no memory of the work already done.

**Root cause (Engine, ShellPilot 0.3.1):** two different tokens share the word.
The OAuth token in the token file is long-lived; `Get-ShpSessionToken` exchanges
it at `https://api.github.com/copilot_internal/v2/token` for a **short-lived
session token** carrying its own `expires_at` — that is the "IDE token" the API
is refusing. `Invoke-Shp` fetches it **once** per Turn and builds `$apiHeaders`
**once**, then reuses that one header hashtable for every tool iteration. A Turn
that outlives its own session token therefore fails on whichever iteration
crosses the expiry. `maxToolIterations` above the default 25 makes this routine.

**Why nothing recovers.** `Invoke-ShpStreamRequest` is the one request path *not*
wrapped in `Invoke-ShpWithRetry`, and it throws a bare `HttpRequestException`;
`Invoke-Shp`'s catch has fallbacks for `store`, `unsupported_api_for_model` and a
rejected reasoning summary but none for 401. On the DeskPilot side
`Test-DpTransientEngineError` excludes 401 by design, and `Invoke-DpTurn`'s retry
is gated on `$turnState.emitted -eq 0`, so a failure after text has streamed can
never be retried without duplicating the answer.

**Second trigger, easier to miss:** `$script:SessionTokenSafetyMarginSec = 60`.
A Turn that starts with 61 seconds left on the cached token is handed a token
that dies almost immediately — so this is not only about half-hour Turns.

**Rule:** an auth failure *during* a Turn is a refresh problem, not a sign-in
problem. Do not send the user to re-authenticate. The fix belongs in the Engine:
re-resolve the token per iteration, force a refresh on a 401 and retry the same
iteration, and keep the safety margin larger than one iteration's worst case.

## An empty Thinking pane is usually the Model, not DeskPilot (2026-08-11)

**Symptom:** with **Show the model's thinking** on, the pane shows only iteration
dividers and tool calls — no reasoning prose. Looks like a broken switch.

**Root cause:** ShellPilot 0.3.1 requests a reasoning summary only on the
`/responses` shape (`$requestReasoning = [bool]$ShowThinking -and ($mode -eq
'responses')`), and only reaches that shape when `-ShowThinking -and -not
$streamingEnabled`. DeskPilot never passes `-DisableStreaming`, so a text Turn is
always `chat` and the summary is never asked for. On the chat stream reasoning
appears only where the provider *volunteers* `reasoning_text` /
`reasoning_content` / `reasoning` deltas: Claude does, the gpt-5 family does not.

**Rule:** before suspecting DeskPilot, check which Model the Turn ran on. The
answer is a ShellPilot trade-off (reasoning summary *or* live answer streaming),
not a DeskPilot defect, and it cannot be fixed here without giving up streaming.

**Not a leak:** every echoed reasoning delta is wrapped in `` `e[3;90m ``, which
`Get-DpStreamFrame`'s `$isTrace` test matches, so reasoning can never be
misclassified as answer text — including the second and later deltas.

**Diagnostics:** section lines in the pane carry `HH:mm:ss` taken from the
Information record's `TimeGenerated`. Because that is the Engine's write time and
not the drain time, a gap in the stamps is the provider or a tool; a pane that
*renders* slower than its own stamps is the browser.

## The first voice for a language is the worst one installed (2026-08-09)

**Symptom:** read-aloud "sounds like from the last decade", flat and unemphasised,
even on a machine with modern voices installed.

**Root cause:** taking the first `getVoices()` entry whose language matches.
Windows enumerates the 2010-era SAPI voices first — on this machine
`Microsoft Hedda Desktop` sorts ahead of `Microsoft Katja`, and Edge's
`Microsoft Katja Online (Natural)` neural voice sorts last. The API offers no
quality field, so the only signals are the name (`Natural`, `Online`, `Neural`,
`Google`, `Desktop`) and `localService === false`, which is true for the network
neural voices in both Edge and Chrome.

**Rule:** rank, never take the first match. Rank the requested language tag above
quality, or an explicit en-GB gets answered in American.

**Related:** the Web Speech API has **no SSML** — `<say-as interpret-as="date">`
is read out literally — so pronunciation can only be fixed by rewriting the text
itself. Rewriting is safe only with a strong contextual cue: a bare four-digit
number is as likely to be a port as a year.

## `utterance.lang` does not choose a voice, and `getVoices()` starts empty (2026-08-09)

**Symptom:** read-aloud set to German still read the answer with an English
voice, and the very first read-aloud after a page load ignored the setting
entirely even once a German voice was installed.

**Root cause, two parts.** (1) `SpeechSynthesisUtterance.lang` is a *hint*.
Browsers fall back to the default system voice — usually the browser's UI
language — unless `utterance.voice` is assigned an actual `SpeechSynthesisVoice`.
(2) Chrome/Edge load the voice list asynchronously and `speechSynthesis.getVoices()`
returns `[]` until it lands, so a voice lookup on the first click finds nothing
and silently falls back.

**Rule:** always resolve and assign a voice (exact tag → any voice sharing the
base tag → `null`), and prime `getVoices()` once at startup so the list is warm
before the first click. Never assume a language tag the user (or storage) supplies
is one the recogniser accepts — validate against the offered list and fall back to
`auto`.

## "Loading…" that never repaints is a blocked JS thread, not a slow server (2026-08-09)

**Symptom:** opening one `.md` file in the explorer froze the whole browser
window with the viewer stuck on "Loading…". Other files opened fine.

**Reading the symptom:** `renderFileView` sets `file-meta` *before* it renders the
body, so a stuck "Loading…" with no meta line means the thread never got back to
the event loop — a pending `fetch` would have left the window responsive. That
ruled out the Host Server before a single line of PowerShell was read.

**Root cause:** `renderMarkdown` did not normalise line endings. Its heading
branch `/^(#{1,3})\s+(.*)$/` has no `m` flag, so `$` matches only end-of-input and
`.` cannot cross a `\r` — the pattern fails on `## Heading\r`. The paragraph
gatherer's exclusion `/^(#{1,3})\s/` has no `$`, so it still matched: the gatherer
consumed zero lines, `i` never advanced, and the `while` loop ran forever. Every
CRLF Markdown file with an ATX heading; agent-written LF files were unaffected,
which is what made it look file-specific.

**Rule:** a line-based parser must normalise `\r\n?` to `\n` at the door, and a
branch's "claim" regex and the fallback's "exclusion" regex must be the same
pattern or the loop can stall. Where they cannot be, the fallback must consume
the current line unconditionally.

**Testing a hang:** assert it out of process. `Start-Process node ... -PassThru`
plus `WaitForExit(30000)` and `Kill($true)` turns a non-terminating loop into a
failed assertion instead of a hung test run.

## A Windows path literal in a unit test is a Linux-only failure (2026-08-09)

**Symptom:** `Checkpoint.Tests.ps1` passed 21/21 on Windows and failed 4 in CI on
Linux. Every failure said the same thing in a different way — `filesTried` false,
`Remove-DpChangeEntry` never called, an injected restore error never surfacing,
`files` count 0 instead of 2. All of them mean `Restore-DpCheckpoint` found **no
files inside the Project**.

**Root cause:** the test built its Project as `'C:\proj'` and its written files as
`"$Root\src\one.ps1"`. On Linux a backslash is an ordinary filename character, so
`C:\proj\src\one.ps1` is neither rooted nor under the Project. The code then takes
the `Join-Path $rootTrim $path` branch, and PowerShell's Unix FileSystem provider
normalises the backslashes to forward slashes while `$rootTrim` — built by
`[IO.Path]::GetFullPath`, which leaves them alone — does not. The boundary check
`StartsWith($rootTrim + $separator)` therefore rejects every path.

**Why the sibling test still passed:** `Get-DpCheckpointSha`'s root filter only
*compares* two `GetFullPath` results, so it never hits the mismatch — which is what
ruled out "`GetFullPath` threw" and pointed at `Join-Path`.

**Fix + rule:** a test that exercises real path arithmetic must use the running
platform's own root — `if ($IsWindows) { 'C:\proj' } else { '/proj' }` — and build
child paths with `[System.IO.Path]::Combine`. A hard-coded `C:\...` is only safe
for a value the code stores and returns verbatim, never for one it takes apart.
The production code was correct on both platforms; only the test data was not.

## Validate `web/assets/app.js` in ESM mode, not plain `node --check` (2026-06-11)

**Symptom:** UI hung on load — no models in the dropdown, Send permanently
disabled, page "frozen." Backend was healthy (models/settings endpoints fine).

**Root cause:** A round-2 multi-edit scrambled a contiguous stretch of `app.js`
(the `explainCustomization` prompt template, and the Command-palette /
`function wireGlobal` header lines were transposed, leaving
`function Command palette (Ctrl/Cmd+K) =====` and deleting `function wireGlobal`).
The browser loads `app.js` as `<script type="module">`, so a syntax error aborts
the **whole** module — `init()` never runs, so `wireGlobal()`/`loadModels()` never
fire (hence empty model list + disabled Send).

**Why it slipped through:** `node --check app.js` returned exit 0. Node 25
auto-detects module type and was lenient enough to pass the malformed source in
CommonJS context; the browser (strict ESM) was not.

**Fix + rule:** Always validate the SPA bundle as an ES module. Copy to a `.mjs`
and check, which reproduces the browser parser exactly:

```powershell
Copy-Item web/assets/app.js "$env:TEMP/appcheck.mjs" -Force
node --check "$env:TEMP/appcheck.mjs"   # exit 1 on the real syntax error
```

Best of all, fetch the **served** bytes and ESM-check those, so you validate what
the browser actually receives:

```powershell
Invoke-WebRequest "http://127.0.0.1:$port/assets/app.js" -Headers $H -OutFile "$env:TEMP/served.mjs"
node --check "$env:TEMP/served.mjs"
```

Syntax-valid-but-semantically-wrong scrambles (e.g. a mangled template literal)
won't be caught by any syntax check — after a large multi-edit, grep for scramble
signatures (`^[^/].*=====`, `function [A-Z][a-z]+ [a-z]`, stray `$n` artifacts)
and read the touched regions back.

## Bridge Engine `Read-Host` prompts through the Host Server (2026-08-05)

**Symptom:** A prompt asking DeskPilot to interview the user produced prose or
continued best-effort instead of an interactive questionnaire, even though the
Ask-User Permission was enabled.

**Root cause:** Permission wiring only offered ShellPilot's `ask_user` Tool.
ShellPilot 0.4.0 then wrote the question and called `Read-Host`; DeskPilot runs
`Invoke-Shp` in an Engine pipeline with no interactive console, so the helper
returned `answered=false`. Enabling a Tool is not enough when its host I/O
contract is console-specific.

**Fix + rule:** Adapt the host boundary. Use ShellPilot's structured
`ShpProgress` `ToolCall` arguments as the semantic question source, shadow
`Read-Host` only in the Engine Runspace during an active Turn, and rendezvous
with a token-gated, Conversation/question-correlated HTTP answer. The Turn loop
must keep pumping pending requests while the Engine waits, and Stop must cancel
the wait. Never parse `Write-Host` colors for Tool semantics.

## Preserve Usage when stopping an Engine pipeline (2026-08-05)

**Symptom:** Stop was acknowledged quickly but the browser stayed active while
`PowerShell.Stop()` unwound, and interrupted Turns showed no credits.

**Root cause:** The Turn loop stopped the child pipeline synchronously and its
cancellation branch returned before creating a Message or calling
`Update-DpUsage`. ShellPilot receives provider Usage in the final stream frame
and appends its Usage log only on normal return, so a hard stop may have no exact
token record.

**Fix + rule:** Freeze the UI synchronously and stop the child pipeline through
`BeginStop`/`EndStop` while the Host Server keeps pumping requests. Persist a
stopped Message. Prefer an exact cumulative Engine Usage delta only when both
pre/post snapshots exist; otherwise use and visibly label an input-only estimate.
Never treat a missing baseline as zero, or all prior Engine Usage can be charged
again. Skip post-Turn Model calls after Stop, and guard already-scheduled paints
with a Turn-local stopped latch.

## Tool descriptions control interaction granularity (2026-08-05)

**Symptom:** The Model emitted structured JSON but still asked one question per
Tool call, so the UI could not present one bundled wizard.

**Root cause:** ShellPilot's built-in `ask_user` Tool explicitly describes a
"single clarifying question." System-prompt guidance to bundle questions did
not reliably override that Tool contract.

**Fix + rule:** Add a dedicated Tool whose description matches the desired
interaction. `ask_questions` accepts one JSON string because ShellPilot's
metadata schema generator cannot express nested question objects. Normalize and
bound that JSON at the Host Server boundary, permission-gate registration per
Turn, and keep the built-in Tool as a plain fallback. Do not parse prose into UI
structure or rely on stronger prompting against a contradictory Tool schema.
