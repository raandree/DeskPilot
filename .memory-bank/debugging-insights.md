# Debugging Insights

Recurring issues and how they were resolved.

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
