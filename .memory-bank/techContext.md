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
- The **Engine** available. DeskPilot resolves it in order: an explicit
  `-EngineModulePath`; an already-installed `ShellPilot` module on `PSModulePath`;
  otherwise a fresh install from the PowerShell Gallery into the CurrentUser scope
  (preview/prerelease versions allowed) via `Resolve-DpEngineModule`, then import
  by name.

## Key integration facts (Engine API)

- `Invoke-Shp -Prompt <text>` returns an object with `.Content`, `.Usage`,
  `.CostUSD`, `.Credits`, `.ToolCalls`, `.FilesRead`, `.FilesWritten`,
  `.CommandsRun`, `.QuestionsAsked`, `.History`, `.Reasoning`, `.ContentObject`.
- Tools are **on by default**; disabled per category with `-DisableBrowsing`,
  `-DisableFileAccess`, `-DisableTerminal`, `-DisableUserPrompts`,
  `-DisableUserTools`.
- Streaming is **on by default**: answer tokens are echoed to the host via
  `Write-Host`; the full text is always on `.Content`. DeskPilot captures the
  host echo through the `[PowerShell]` instance's `Streams.Information` to drive
  live SSE deltas, and uses `.Content` as the authoritative final text.
- Stateless multi-turn via `-History` (an array of `{role, content}`). DeskPilot
  stores one history array per Conversation and replays it each Turn — this
  isolates Conversations and avoids the Engine's module-scoped running chat.
- Model control: `Get-ShpModel`, `Get-ShpModelName`, `Select-ShpModel`.
- Auth: `Initialize-Shp` runs the GitHub device-code flow once; the token is
  cached at `$env:USERPROFILE\.copilot-demo-token`.
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
  web/               # static SPA (index.html, css, js, assets)
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
