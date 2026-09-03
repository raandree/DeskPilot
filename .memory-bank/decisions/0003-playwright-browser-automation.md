---
schema-version: 1
status: accepted
owner: software-engineer
last-verified: 2026-09-02
source: repository evidence
---

# 0003 — Playwright browser automation: stop at the prerequisite gate

## Status

**Blocked.** Three of the gate's requirements are unmet and one cannot be
resolved without the user.

> **Partly superseded 2026-09-03.** Per-call approval shipped for Terminal
> (decision 0008), so that bullet below is stale. Isolated execution is still
> unshipped and the product decisions are still unanswered, so the verdict is
> unchanged.

## The gate

`.github/prompts/implement-browser-automation.prompt.md`:

> Require shipped per-call approval and isolated execution. Require the user to
> name the first workflow, target environment, permitted domains, required
> private data, and allowed outbound actions. If any is unspecified, stop and ask
> for those decisions before writing code.

- **Per-call approval:** not shipped (`specs/120`, decision 0001).
- **Isolated execution:** not shipped (decision 0001).
- **Workflow, environment, domains, data, actions:** unspecified. These are
  product decisions about someone else's systems; they cannot be inferred from
  repository evidence, and the user is unavailable.

All three must hold. The prompt's instruction on an unmet gate is to stop, and
it is right to: this feature exists specifically to carry reviewed work into an
external system, which is an irreversible outbound effect.

## Current baseline, verified

DeskPilot's browser capability is the static SPA plus the Engine's `fetch_url`
Tool. It can retrieve and read a URL; it cannot inspect a live DOM, click a
control, fill a field, or drive a browser. No Playwright dependency is declared
in `RequiredModules.psd1` or anywhere else, and none was added.

## Decisions recorded for when the gate opens

**Binding and runtime.** Official `playwright` Node package, driven from
PowerShell over a supervised child process. Rationale: the .NET binding would
put browser control inside the Host Server process, and the Engine Runspace is
already the single-threaded resource everything else queues behind. A separate
process is also what makes "Stop kills the whole tree" implementable.

**Node.js ownership.** DeskPilot does **not** bundle Node. It detects a
supported Node, reports its absence in Diagnostics, and offers a consent-gated
install pointing at the official distribution. Silently downloading an
executable runtime is exactly what the security model forbids.

**Browser binaries.** Pinned Playwright version with its matching browser build,
installed only on explicit consent into the DeskPilot data directory, verified by
Playwright's own version check before a Turn starts. Offline start with a
missing or mismatched binary fails visibly; it never falls back to a locally
installed browser, because that browser's profile is the user's.

**Profile.** A dedicated disposable profile per run: no personal cookies,
extensions, password store, history, downloads, or ambient SSO. Visible, not
headless, for the first user-facing workflow.

**Permission.** A separate `browserAutomation` Permission, off by default.
Browsing Permission must not imply it.

## Trifecta assessment

The prompt requires breaking at least one leg by architecture:

- **Private data:** breakable — pass only task-scoped typed values, never the
  Workspace Folder, clipboard, home directory, or credentials.
- **Egress:** breakable — a domain and scheme allow-list enforced *below* the
  Model, blocking unknown redirects, pop-ups, WebSockets, downloads, and
  URL-bearing resource loads.
- **Agency:** only partially breakable without per-call approval, which is the
  gate. Without it, an injected page and an irreversible submission are one
  Model decision apart.

That is the substantive reason the gate exists, not a procedural one.
