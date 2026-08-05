---
schema-version: 1
status: accepted
owner: shared
last-verified: 2026-08-05
source: repository evidence
---

# Project Brief — DeskPilot

## What

DeskPilot is a local, desktop-style graphical interface that lets non-technical
users operate a full GitHub Copilot **agent** — with the same tools and
permissions as Copilot in VS Code — through a clean, modern chat
experience. It fronts **ShellPilot** (the PowerShell module that talks to GitHub
Copilot) and is designed to make the **Agentic Operating Model** approachable to
people who cannot, or do not want to, drive the underlying tool stack from a
terminal or IDE.

## Why

The Agentic Operating Model ([raandree/AgenticOperatingModel](https://github.com/raandree/AgenticOperatingModel))
teaches a new way of working: versioned, agent-assisted knowledge work across
code, operations, research, and correspondence. Practising it today requires
comfort with VS Code, PowerShell, Git, and a deep customization stack
(instructions, skills, agents, MCP). That excludes most knowledge workers.
DeskPilot removes the barrier: one window, a prompt box, and the same agent
power underneath.

The Agentic Operating Model uses [**CopilotAtelier**](https://github.com/raandree/CopilotAtelier)
as the canonical example of a mature personal **Atelier** — a repo that
curates `~/.copilot/{agents,instructions,skills,prompts}` across machines via
OneDrive + NTFS junctions (Modules 3 and 8). Because DeskPilot defaults its
`agentsRoot`, Skill roots and Instruction roots from `~/.copilot`, a
CopilotAtelier-managed Atelier feeds DeskPilot's Agent picker and tool-config
roots with no extra setup; it is the recommended companion for any user who
keeps customizations across more than one machine.

## Goals

- **G1 — Parity.** Expose the full ShellPilot agent surface: browse, read/list/
  write files, run commands, ask-user, user-defined tools, skills, instructions,
  model choice, vision, structured output, usage/cost.
- **G2 — Approachability.** A calm, Claude-like UI a non-technical user can
  operate with zero terminal knowledge.
- **G3 — Safety with clarity.** Tool permissions are visible and controllable;
  risky capabilities are explained, not hidden.
- **G4 — Local-first.** Runs entirely on the user's machine; no extra cloud
  service. Only prerequisites are PowerShell 7 and a Copilot-enabled GitHub
  account (the same as ShellPilot).
- **G5 — Teachable.** Mirrors the Agentic Operating Model vocabulary and
  patterns, so DeskPilot doubles as an on-ramp to the training.

## Non-goals

- Not a replacement for VS Code Copilot for developers who already have it.
- Not a multi-tenant hosted service (one local user per instance).
- Not a re-implementation of Copilot endpoints — that is the Engine's job.

## Stakeholders

- **Primary user:** a knowledge worker (analyst, ops engineer, lawyer,
  researcher) who wants agentic help without the tool stack.
- **Curator/owner:** the AgenticOperatingModel author and contributors.
- **Engine owner:** ShellPilot maintainers.

## Success criteria

- A first-time user can authenticate, pick a Model, and complete a tool-using
  Turn (e.g. "summarise these files and write a memo") without touching a
  terminal.
- Every Copilot agent capability available in the Engine is reachable from the
  UI.
- Permissions are always visible; nothing destructive happens without the
  relevant Permission switched on.
