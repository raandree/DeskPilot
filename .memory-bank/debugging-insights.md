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

