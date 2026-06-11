# 000 — Overview

## Vision

DeskPilot is the friendly front door to agentic knowledge work. It gives a
non-technical user the same GitHub Copilot **agent** that a developer has in VS
Code — able to browse, read and write files, run commands, follow Skills and
Instructions, and reason over a corpus — wrapped in a calm, modern chat
window that needs no terminal, no IDE, and no tool-stack knowledge.

It exists to make the **Agentic Operating Model** ([raandree/AgenticOperatingModel](https://github.com/raandree/AgenticOperatingModel))
reachable for the people it is meant to serve but who cannot drive the stack:
analysts, operators, lawyers, and researchers.

The Agentic Operating Model uses [**CopilotAtelier**](https://github.com/raandree/CopilotAtelier)
as its reference exemplar of a "mature personal Atelier" (Modules 3 and 8):
a single repo that curates `~/.copilot/{agents,instructions,skills,prompts}`
across machines via OneDrive + NTFS junctions. DeskPilot already discovers
exactly that layout (defaulting `agentsRoot` and the Skill/Instruction roots
from `~/.copilot`), so a CopilotAtelier-managed Atelier feeds straight into
DeskPilot's Agent picker, Skill roots, and Instruction roots without extra
wiring.

## Scope

### In scope (v1)

- A local Host Server (PowerShell) that hosts the Engine (ShellPilot) and serves
  a web UI.
- A calm, modern single-page UI: Conversations, streaming Messages, composer.
- Full parity with the Engine's agent Tools (Browsing, File, Terminal, Ask-User,
  User Tools) surfaced as visible Permissions.
- Model selection; named **Projects** (registered Workspace Folders with a
  folder picker); an **Agent** picker (personas from `*.agent.md` files);
  Skill/Instruction roots; reasoning effort.
- A collapsible **file explorer** for the selected Project.
- **Back up / restore** of all settings as JSON.
- Per-Turn Activity and Usage (tokens, cost, credits), plus a persisted
  lifetime credit counter.
- In-UI GitHub device-code authentication.

### Out of scope (v1)

- Multi-user / hosted operation.
- A bundled installer (documented manual launch first).
- Re-implementing any Copilot endpoint, Tool, or auth (the Engine owns these).

## Audience

See [productContext](../.memory-bank/productContext.md). Primary persona: a
knowledge worker who wants agentic help without the tool stack.

## How the pieces fit

| Piece | Role |
| --- | --- |
| **DeskPilot** | The product — UI + Host Server. |
| **Host Server** | PowerShell HTTP + SSE bridge; owns Conversations, Settings, streaming. |
| **Engine (ShellPilot)** | Talks to GitHub Copilot; provides Tools, Skills, Models, Usage. |
| **GitHub Copilot** | The upstream model + agent service. |

## Document map

| Spec | Contents |
| --- | --- |
| [010-requirements](010-requirements.md) | Functional & non-functional requirements (MoSCoW). |
| [020-architecture](020-architecture.md) | Components, runspace model, streaming, data flow. |
| [030-api-contract](030-api-contract.md) | REST + SSE endpoints and schemas. |
| [040-ui-design](040-ui-design.md) | Layout, screens, visual language, states. |
| [050-security-model](050-security-model.md) | Threat model, permissions, guardrails. |
| [060-roadmap](060-roadmap.md) | Phased delivery plan. |

## Terminology

All documents and code use the canonical terms in
[glossary](../.memory-bank/glossary.md). Notably: **Engine** = ShellPilot,
**Conversation** = a chat thread, **Turn** = one prompt+response, **Tool** = an
agent capability, **Permission** = a user switch over a Tool category.
