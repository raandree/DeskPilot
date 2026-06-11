<!-- markdownlint-disable MD033 MD041 -->
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="web/assets/logo-mark-dark.png">
  <img align="right" width="112" alt="DeskPilot logo" src="web/assets/logo-mark.png">
</picture>
<!-- markdownlint-enable MD033 MD041 -->

# DeskPilot

A calm, modern desktop chat window that gives a non-technical user the full
GitHub Copilot **agent** — able to browse, read and write files, run commands,
and follow Skills and Instructions — without a terminal or an IDE.

DeskPilot is the friendly front door to the
[Agentic Operating Model](https://github.com/raandree/AgenticOperatingModel):
it fronts the [ShellPilot](https://github.com/raandree/ShellPilot) engine (which
talks to GitHub Copilot) with a local web UI, so the people the model is meant to
serve — analysts, operators, lawyers, researchers — can do agentic knowledge
work without driving the tool stack themselves.

> **Status: experimental pre-release.** DeskPilot builds on ShellPilot, which
> talks to internal Copilot endpoints intended for first-party editors. They may
> change without notice. See [Security](#security).

## What it gives you

- **A real agent, not autocomplete.** Every message drives a Copilot agent with
  the same tools VS Code Copilot has.
- **Visible permissions.** Five tool categories — Browsing, Files, Terminal,
  Ask-you, Your tools — each a switch you control, with plain-language risk
  notes. Terminal is **off** by default.
- **Show the work.** Each answer carries an Activity panel: what was read,
  written, run, fetched, or asked.
- **Honest cost.** Token usage, estimated USD cost, and Copilot credits after
  every turn.
- **Your house rules.** Point it at folders of Skills and Instructions — the
  same files VS Code Copilot uses — and the agent discovers them.
- **Calm, build-free UI.** A static single-page app served locally. No npm, no
  bundler, nothing for you to install beyond PowerShell 7.

## Requirements

- **PowerShell 7.0+** (Windows, macOS, or Linux).
- A **GitHub account with Copilot access**.
- The **ShellPilot** engine module available (built from source or installed).
  DeskPilot probes common locations and falls back to importing it by name; you
  can also pass an explicit path.
- A modern browser.

## Quick start

```powershell
# From the repo root
./Start-DeskPilot.ps1
```

Or on Windows, double-click `DeskPilot.cmd`.

The launcher starts the local Host Server, prints a URL such as
`http://127.0.0.1:8473/?t=<token>`, and opens your browser. On first run it walks
you through GitHub sign-in (device code) from inside the window.

### Pointing at a specific engine build

```powershell
./Start-DeskPilot.ps1 -EngineModulePath 'V:/Git/ShellPilot/output/module/ShellPilot/0.0.1/ShellPilot.psd1'
```

### Options

| Parameter | Meaning |
| --- | --- |
| `-Port <int>` | Port to listen on. `0` (default) picks a free one. |
| `-EngineModulePath <path>` | Explicit path to the ShellPilot module. |
| `-NoBrowser` | Do not open the browser automatically. |

## How it works

```text
Browser (static SPA)  ──REST/SSE──▶  Host Server (PowerShell)  ──Invoke-Shp──▶  Engine (ShellPilot)  ──▶  GitHub Copilot
```

- The **Host Server** is a small PowerShell HTTP + Server-Sent-Events bridge. It
  owns conversations, settings, and streaming, and runs every turn on a single
  long-lived **Engine runspace**.
- The **Engine** (ShellPilot) does all the Copilot work: tools, skills, models,
  usage, and auth. DeskPilot re-implements none of it.
- Answers **stream** token-by-token to the browser; the final text, the Activity,
  and the Usage are sent when the turn completes.

See the [specs](specs/000-overview.md) for the full design, and the
[memory bank](.memory-bank/projectbrief.md) for project context.

## Project layout

```text
assistant/
  .memory-bank/        Project knowledge base (brief, context, patterns, glossary)
  specs/               Product + technical specifications
  src/DeskPilot/        Host Server PowerShell module
  web/                 Static single-page UI (no build step)
  tests/               Pester 5 tests for the Host Server helpers
  Start-DeskPilot.ps1  Launcher
  DeskPilot.cmd        Double-click launcher (Windows)
```

## Security

DeskPilot hands you an agent that acts with **your** privileges. That power is
the point and the risk. DeskPilot keeps it visible and governable; it does not
sandbox the agent.

- **Localhost only.** The Host Server binds to `127.0.0.1` and requires a random
  per-launch session token on every API call, so other local processes cannot
  drive your agent.
- **Permissions are explicit.** A tool that is switched off is never offered to
  the model. Terminal and Files are flagged as powerful; Terminal defaults off.
- **Workspace folder is a default, not a jail.** It sets where file and terminal
  tools work by default; the agent can still use absolute paths. Point it at a
  dedicated, version-controlled folder so changes are diffable and revertible.
- **Inherited engine caveats.** ShellPilot caches its OAuth token in clear text
  and calls internal Copilot endpoints. Use a single-user machine.

See [specs/050-security-model.md](specs/050-security-model.md) for the full
threat model.

## Running the tests

Tests use Pester 5. Run them in a detached process (so VS Code never blocks):

```powershell
Start-Process pwsh -ArgumentList '-NoProfile','-NonInteractive','-Command',
  "Set-Location '$PWD'; Import-Module Pester -MinimumVersion 5.0 -Force; Invoke-Pester -Path ./tests -Output Detailed" `
  -WindowStyle Hidden -Wait
```

## Roadmap

Stop-a-turn and live activity, disk persistence, an Ask-you card in the thread,
vision and structured output, a user-tool manager, and a WebView2 single-window
shell. See [specs/060-roadmap.md](specs/060-roadmap.md).

## License

MIT.

## See also

- [ShellPilot](https://github.com/raandree/ShellPilot) — the engine.
- [Agentic Operating Model](https://github.com/raandree/AgenticOperatingModel) —
  the operating model DeskPilot makes approachable.
- [CopilotAtelier](https://github.com/raandree/CopilotAtelier) — the canonical
  personal **Atelier** referenced by the Agentic Operating Model (Module 3:
  *Your Atelier — Customization as Code*; Module 8: *A Mature Personal
  Atelier*). It curates `~/.copilot/{agents,instructions,skills,prompts}`
  across machines via OneDrive + NTFS junctions, which is exactly the layout
  DeskPilot already discovers (so a CopilotAtelier-managed Atelier appears in
  DeskPilot's Agents picker and Skill/Instruction roots out of the box).
