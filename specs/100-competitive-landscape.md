# Spec 100 — Competitive landscape and feature gaps

> Status: research note, 2026-08-05. Sources are each project's own README as
> published on GitHub and fetched on that date; star counts and feature claims
> are the projects' own and are **not** independently verified. Treat every entry
> as a lead to confirm before it drives a commitment.

## Why this document exists

DeskPilot's thesis — *give a non-technical knowledge worker a real coding-grade
agent without a terminal or an IDE* — is no longer unique. A cluster of desktop
agent clients now competes for the same user. This note records what they ship,
where DeskPilot is genuinely ahead, and which gaps are worth closing.

## The comparable set

| Project | What it is | Notable |
| --- | --- | --- |
| **Hermes One** (`fathah/hermes-desktop`, ~13.7k★, MIT, Electron/TypeScript) | Community desktop companion for NousResearch's Hermes Agent. Installs and configures the agent, then gives it a GUI. | The most feature-complete "agent front door" in the set. Explicitly the template the user pointed at. |
| **LiveAgent** (`Stack-Cairn/LiveAgent`, ~1.7k★, MIT, Tauri/Rust + Go) | Local-first agent desktop with an optional remote Gateway and browser WebUI. | The most architecturally ambitious: MCP bridging, sub-agent worktree isolation, per-tool approval. |
| **wesight** (`freestylefly/wesight`, ~850★, Electron) | One-click setup workspace for Claude Code / Codex / OpenClaw / Hermes with custom model routing. | Positions itself as a launcher, not an agent. |
| **clawpier** (`SebastianElvis/clawpier`, ~70★, Tauri v2) | Manages **sandboxed** agent instances via Docker. | The only one in the set whose headline feature is isolation. |
| **VS Code Copilot Chat** | The reference experience DeskPilot's Changes card and diff viewer are modelled on. | Sets user expectations for changed-file review, Keep/Undo, and diff presentation. |

## What DeskPilot already does better

These are real differentiators; do not trade them away while closing gaps.

1. **A non-expert Git story.** No comparable ships a guided merge with
   AI-proposed conflict resolution (spec 070), a clone wizard (spec 080), or the
   Changes / Branch Wizard surface (spec 090). LiveAgent automates worktree
   merges for sub-agents, but it is not a *user-facing*, plain-language Git UI.
2. **Zero-build frontend.** Static HTML/CSS/JS served by the Host Server. Every
   comparable requires Electron or Tauri plus a JS toolchain.
3. **Copilot-native.** DeskPilot inherits GitHub Copilot's models, entitlements
   and enterprise posture through the Engine rather than asking a
   non-technical user to obtain and paste provider API keys.
4. **Customization-native.** Agents, Skills, Instructions and Prompt files are
   first-class and editable in-app, aligned with `~/.copilot` and CopilotAtelier.
5. **A calm, single-purpose UI.** The comparables accumulate surface area (a 3D
   office, 16 messaging gateways). DeskPilot's audience is served by fewer, more
   legible screens.

## Gaps, ranked

Priority uses MoSCoW as in [010-requirements](010-requirements.md).

| # | Gap | Seen in | Priority | Note |
| --- | --- | --- | --- | --- |
| 1 | **No sandbox.** File and Terminal Tools run with the user's full privileges. | clawpier (Docker), LiveAgent (approval gate) | M | Already the top risk in [050-security-model](050-security-model.md). The cheapest large win is #2, not full containerisation. |
| 2 | **No per-call approval.** Permissions are per *category*, decided before the Turn; a single `rm -rf` inside an allowed category is never confirmed. | LiveAgent ("per-tool execution approval gate") | M | Fits DeskPilot's "surface, don't hide" pattern exactly. Propose: an opt-in "ask me before each Terminal command / file write outside the Project". |
| 3 | ~~**No MCP support.**~~ **Closed (2026-08-12).** ShellPilot 0.4.0-preview0007 added a stdio MCP client (Engine spec 021); DeskPilot owns the durable server list, reconciles it into the Engine Runspace, and surfaces it in Settings → MCP servers. | LiveAgent (stdio + http MCP bridging) | S | Pursued via the Engine as planned, not by forking tool execution. Streamable HTTP is still out on the Engine side. |
| 4 | **No installer.** Manual launch; documented as out of scope for v1. | Hermes One (signed MSI/DMG/RPM), LiveAgent (signed + notarized, MSI/portable/AppImage/DEB/RPM) | S | The single biggest adoption barrier for the stated persona. |
| 5 | **No scheduled or recurring work.** | Hermes One (cron + 15 delivery targets), LiveAgent (bash/http/prompt cron) | S | "Every Monday, summarise X" is a natural knowledge-worker ask. |
| 6 | **No math or diagram rendering.** Artifacts cover `html`/`svg` only. | LiveAgent (KaTeX, Mermaid, Monaco) | S | Mermaid and KaTeX both have build-free ESM builds, but each is a third-party dependency the no-build constraint currently forbids — decide deliberately. |
| 7 | **English only.** | Hermes One, LiveAgent (both i18n) | S | DeskPilot's own users work in German. An i18n pass is mostly mechanical. |
| 8 | **No parallel sub-agents.** One Turn at a time; concurrency is explicitly out of scope. | LiveAgent (worktree isolation + automatic merge) | C | Spec 090 supplies the Git machinery this would need. |
| 9 | **No remote access.** Localhost-only by design. | Hermes One (16 messaging gateways), LiveAgent (Go Gateway + WebUI) | C | Deliberate. If revisited, only as an explicitly authenticated, documented opt-in — never a silent `0.0.0.0` bind. |
| 10 | **Undo is only ever "back to the last commit".** | Claude Code-style checkpoints | C | Spec 090's **Keep** narrows this a lot (commit early, undo precisely). A pre-Turn snapshot would close it entirely. |
| 11 | **No log viewer or diagnostics dump.** | Hermes One (log viewer, debug dump) | C | Would shorten every support loop. |
| 12 | **Single provider.** Copilot only. | Hermes One (11+ providers, local models), LiveAgent (Claude/Codex/Gemini + custom base URL) | W | A deliberate strategic choice, not an oversight. Record it as such. |
| 13 | **No spoken replies.** Dictation in, text out. | Hermes One (TTS) | W | Low value for the stated persona. |

## Recommended order

1. **Per-call approval for Terminal and out-of-Project writes** (gap 2) — the
   largest safety improvement per unit of work, and it needs no new dependency.
   Now sharper than when this was written: an attached MCP server runs
   unsandboxed and no Permission narrows it.
2. **An installer** (gap 4) — removes the last "ask a developer for help" step.
3. **Scheduled tasks** (gap 5) — the clearest unserved knowledge-worker workflow.
4. **i18n** (gap 7) — mechanical, and directly serves current users.
5. ~~**MCP** (gap 3)~~ — shipped 2026-08-12 via the Engine, as planned.

Everything below that line should wait for evidence of demand.

## What to verify before committing

Every claim above is a project's own marketing. Before any of it becomes a
requirement:

- Confirm LiveAgent's approval gate really is per *call* and not per session.
- Confirm the MCP bridge's transport coverage and whether it would sit in
  DeskPilot or in the Engine.
- Measure how much of gap 6 a build-free KaTeX/Mermaid ESM bundle actually costs
  in page weight and startup time.
- Check the licence and provenance of anything bundled.
