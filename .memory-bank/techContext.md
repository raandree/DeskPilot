---
schema-version: 1
status: accepted
owner: shared
last-verified: 2026-08-05
source: repository evidence
---

# Tech Context — DeskPilot

## Stack

| Layer | Technology | Why |
| --- | --- | --- |
| Engine | **ShellPilot** (PowerShell module) | Already speaks the GitHub Copilot agent protocol: streaming, tools, skills, instructions, usage/cost. DeskPilot does not re-implement any of this. |
| Host Server | **PowerShell 7** + `System.Net.HttpListener` | In-process hosting of the Engine; no extra runtime; pure-PowerShell HTTP + Server-Sent Events. Fits the existing PowerShell/Sampler/Pester ecosystem. |
| Transport to UI | **HTTP REST + SSE** (Server-Sent Events) | REST for state (models, settings, conversations); SSE for live token streaming of a Turn. Simpler and more robust than WebSockets for one-directional streaming. |
| Frontend | **Static SPA** — vanilla HTML/CSS/JS, no build step | Zero toolchain for end users; the Host Server serves the files directly. A calm, deep-teal, dependency-free UI. |
| Launcher | `Start-DeskPilot.ps1` + a double-click `.cmd` | One action to start the server and open the browser. |
| Tests | **Pester 5** | Matches workspace conventions; unit-tests Host Server helpers and routing. |
| Build | **Sampler** (ModuleBuilder, InvokeBuild, GitVersion, PSScriptAnalyzer) | Mirrors ShellPilot. Source in `source/`, built to `output/module/DeskPilot/<version>/`; version from GitVersion. `./build.ps1` runs build/test/pack/publish workflows. |

## Prerequisites (end user)

- Windows, macOS, or Linux with **PowerShell 7.0+**.
- A **GitHub account with Copilot access** (same as the Engine).
- A modern browser (the UI runs at `http://127.0.0.1:<port>`).
- The **Engine** available. DeskPilot resolves it at runtime via
  `Resolve-DpEngineModule`: an explicit `-EngineModulePath`, else an
  already-installed `ShellPilot` on `PSModulePath`, else a fresh CurrentUser
  install from the Gallery (preview/prerelease allowed), then imports by name.
  ShellPilot is intentionally NOT a hard manifest `RequiredModule`, so importing
  DeskPilot never fails when the Engine is absent.

## Key integration facts (Engine API)

- `Invoke-Shp -Prompt <text>` returns an object with `.Content`, `.Usage`,
  `.CostUSD`, `.Credits`, `.Reasoning`, `.ToolCalls`, `.FilesRead`,
  `.FilesWritten`, `.CommandsRun`, `.QuestionsAsked`, `.History`,
  `.ContentObject`.
- **Cost comes only from the Engine, and can be absent.** ShellPilot prices a
  Turn from `data/PriceTable.psd1`, keyed by the **exact lowercased Model id**
  with no family fallback (`$priceKey` tries the response's `ModelName` then the
  requested `-Model`). A Model missing from that table yields `.CostUSD` and
  `.Credits` of **`$null`** - measured live for `claude-opus-5`, which the 0.3.1
  table does not list. Credits are derived (`costUSD / 0.01`), not reported by
  the provider; no billing multiplier is exposed anywhere in the Engine. Fix a
  missing rate upstream in ShellPilot, never by pricing in DeskPilot.
- Tools are **on by default**; disabled per category with `-DisableBrowsing`,
  `-DisableFileAccess`, `-DisableTerminal`, `-DisableUserPrompts`,
  `-DisableUserTools`.
- ShellPilot 0.4.0's built-in `ask_user` describes one free-text question.
  DeskPilot adapts its `Read-Host` contract and also registers `ask_questions`,
  a trusted User Tool whose string parameter carries bounded nested JSON for a
  bundled Questionnaire. It is removed when Ask-User Permission is off and is
  hidden by ShellPilot when general User Tools Permission is off.
- Streaming is **on by default**: answer tokens are echoed to the host via
  `Write-Host`; the full text is always on `.Content`. DeskPilot captures the
  host echo through the `[PowerShell]` instance's `Streams.Information` to drive
  live SSE deltas, and uses `.Content` as the authoritative final text.
- A hard pipeline Stop can prevent ShellPilot from receiving the provider's
  final token/Usage frame. DeskPilot uses an exact pre/post Engine Usage delta
  only when both snapshots exist; otherwise it persists and labels ShellPilot's
  preflight input-only cost estimate (`estimated`, `partial`, `estimateScope`).
- Stateless multi-turn via `-History` (an array of `{role, content}`). DeskPilot
  stores one history array per Conversation and replays it each Turn — this
  isolates Conversations and avoids the Engine's module-scoped running chat.
- Model control: `Get-ShpModel`, `Get-ShpModelName`, `Select-ShpModel`.
- Native Vision input: `Invoke-Shp -Image <string[]>` accepts local image paths
  or HTTP(S) URLs. DeskPilot forwards only local image Attachment paths that the
  current Host Server launch successfully accepted through `/api/uploads`.
- Auth: `Initialize-Shp` runs the GitHub device-code flow once; the Engine caches
  the token as a hidden dot-file in the user's home directory. The filename is the
  Engine's own default and is NOT stable across versions (ShellPilot renamed it
  from `.copilot-demo-token` to `.shellpilot-token` in 0.2.1), so DeskPilot never
  hardcodes it: `Initialize-DpEngine` probes the imported Engine's
  `$script:DefaultTokenPath` and uses that for the "signed in?" check
  (`Test-Path`), falling back to the current name — preferring an existing legacy
  token — when the probe is unavailable.
- Skills/instructions: `-SkillPath`, `-InstructionRoot`, `-InstructionPath`.
- No native Agent or System-prompt-file concept beyond `-SystemPrompt` /
  `-SystemPromptPath`; DeskPilot's **Agents** are `*.agent.md` files (default
  `~/.copilot/agents`) whose body it passes as `-SystemPrompt`. Skill/Instruction/
  Prompt roots and the Agents folder default from
  `~/.copilot/{skills,instructions,prompts,agents}`. DeskPilot also surfaces these
  files for browse/edit in its **Customizations** view (Agents, Skills,
  Instructions, Prompt files), confined to the configured roots.

## Persisted data (per-user data directory)

Resolved as `$LOCALAPPDATA/DeskPilot` → `$XDG_DATA_HOME/DeskPilot` →
`~/.local/share/DeskPilot` (overridable with `Start-DeskPilot -DataDir`). Holds
`conversations.json`, `lifetime-usage.json`, and `settings.json`. All writes are
atomic (temp file + `Move-Item -Force`).

## Constraints & risks

- **Internal endpoints.** The Engine calls private Copilot services that can
  change without notice (inherited risk).
- **Clear-text token.** The Engine caches the OAuth token unencrypted. DeskPilot
  does not change this; it is documented in the Security spec.
- **No path sandboxing.** Engine File/Terminal tools run with the user's full
  privileges. DeskPilot mitigates with a Workspace Folder default and visible
  Permissions, not with a true sandbox.
- **Localhost only.** The Host Server binds to `127.0.0.1` by default and must
  never bind to a public interface without an explicit, documented opt-in and
  auth.
- **Single user.** The Host Server assumes one local user; concurrency beyond a
  single active Turn is a future enhancement.

## Repo layout

```text
DeskPilot/
  .memory-bank/      # this knowledge base
  specs/             # product + technical specifications
  source/            # Host Server PowerShell module (Public/Private/manifest; built by Sampler)
    web/             # static SPA (index.html, css, js, assets); bundled into the built module via CopyPaths
  tests/             # Pester 5: tests/QA (module quality) + tests/Unit
  output/            # build output, gitignored (built module + test results)
  build.ps1          # Sampler build bootstrap
  build.yaml         # Sampler build configuration
  RequiredModules.psd1  # build + runtime dependencies
  GitVersion.yml     # versioning (main is the mainline)
  Start-DeskPilot.ps1  # launcher (builds on first run, imports the built module)
  DeskPilot.cmd        # double-click launcher (Windows)
  README.md
  CHANGELOG.md
```
