---
schema-version: 1
status: accepted
owner: shared
last-verified: 2026-08-05
source: repository evidence
---

# Active Context

## Current focus

**Stop is immediate and interrupted Usage is shown (2026-08-05; uncommitted on
`main` at the user's request, not pushed).** The Stop route was accepted quickly,
but the browser stayed in Streaming while the Host Server synchronously called
`PowerShell.Stop()`. The cancellation branch then emitted only an error and
returned before mapping, accruing, or persisting Usage.

The browser now enters a disabled **Stopping…** state synchronously, removes the
spinner/caret, and ignores buffered or scheduled stream paints. The Host Server
uses `BeginStop`/`EndStop`, pumps pending requests while the Engine pipeline
unwinds, and emits `stopping` then `stopped`. A stopped assistant Message is
persisted with partial Usage. An exact Engine Usage delta is used only when both
pre/post snapshots exist; otherwise a clearly labelled input-only estimate is
accrued and displayed. Post-Turn title, compaction, and Memory calls do not run
after Stop.

## Verification

- TDD red baselines captured for immediate UI state, stopped Usage mapping,
  StrictMode-safe estimate input, missing-baseline overcount, persistence, and
  scheduled-paint cancellation.
- Full Sampler build and test: **426 passed**, 0 failed, exit 0.
- Live Host Server smoke: `start → stopping → stopped`, Stop acknowledged in
  **123 ms**, `0.0065` estimated input credits accrued and persisted.
- Browser smoke: Stop DOM changed in **0.8 ms**; final Message showed
  `~0.0065 credits (input estimate)` and the button returned to **Send**.
- Independent review and focused re-review approved after the missing-baseline
  accounting guard; no Blocker, Major, or agent-security finding remains.

## Next step

Try Stop on the running source server. Commit only when the user asks; do not
push without an explicit request.

## Previous focus

Interactive Ask-User questionnaires are implemented through a correlated
Runspace prompt bridge. This remains uncommitted on `main` alongside the Stop
and sign-in fixes.
