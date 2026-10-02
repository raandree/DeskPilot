---
schema-version: 1
status: accepted
owner: software-engineer
last-verified: 2026-10-02
source: operator request for screenshot-style Subagent handling, Engine spec 045, and red/green tests against the installed Engine
---

# 0012 - Bounded Subagents

## Context

On 2026-10-02 the operator asked for Subagent handling like VS Code's chat
shows it: the Model hands a task to another agent, and the window shows the
run, its input, its output and whether it completed. Nobody was available to
answer questions, so this record states the scope that was chosen.

[Decision 0005](0005-parallel-agents.md) withholds **parallel** Agents and any
concurrency in the shared Engine Runspace. [Decision 0009](0009-single-child-isolation.md)
and [0010](0010-child-budget-estimates.md) cover an **isolated child run** that
an operator starts in a credentialless container. Neither describes what was
asked for here, and both remain unchanged.

The installed Engine (ShellPilot 0.4.0-preview0016, identical to ShellPilot
`main` for the four functions involved) ships `Invoke-ShpSubagent`, spec 045: a
synchronous nested Turn in the current Runspace that is a **strict subset** of
its parent, inside a shared budget, returning an answer rather than a
transcript. It refuses to widen and has no background mode.

## Decision

Adopt the Engine's bounded Subagents as a Model-callable DeskPilot User Tool,
`run_subagent`, behind a new **Subagents** Permission that ships off.

- **No concurrency.** One Subagent runs at a time while the Turn waits. The
  screenshot's *background* agents stay out of scope; decision 0005's gate
  stands.
- **No new authority.** The parent capability is the Turn's own `Disable*`
  switches and, under broader approval, the very `ToolCallControl` object the
  Turn runs under. The legacy `ToolCallApprover` cannot be inherited, so it
  turns Subagents off rather than letting a child run ungated.
- **Narrowed further.** `run_subagent` and `ask_questions` are withheld
  (`ExcludeTool`; the Engine refuses to dispatch a known Tool it did not offer),
  the Task List is disabled, depth is 1, concurrency and fan-out per dispatch
  are 1, and a re-entrancy guard refuses a nested dispatch. A Subagent's
  Terminal command is approved once only: it neither uses nor creates the
  Turn-wide grant of decision 0011.
- **Host-owned inputs.** The Model names a Subagent; the Host-built catalog maps
  the name to a definition path. Catalog, capability, Turn identity, limits and
  ledger travel as a runspace global, never as Tool parameters.
- **Catalog.** The bundled `general-purpose` definition plus every Agent with a
  `name` and a `description`, within 256 KiB, that does not set
  `disable-model-invocation: true`. The selected Agent's `agents:` list narrows
  it as in VS Code; `agents: []` offers none. An Agent's VS Code `tools:` and
  `model:` lists are not interpreted, consistent with the Agent picker.
- **Own Invoker.** The Engine's dispatcher has no Model, so a child would run on
  the session default. DeskPilot's Invoker mirrors `Invoke-ShpSubagentTurn` key
  for key and adds only `Model`, `ReasoningEffort`, `DisableTodoList`,
  `ExcludeTool` and a working-directory note. A test captures the installed
  Engine's own translation and fails if any parameter it binds is missing or
  not the same object.
- **Bounded.** Per Turn: 5 runs and USD 2.00. Per run: USD 0.50, the Turn's
  `maxToolIterations` capped at 30, 900 seconds, a 20,000-character task, and a
  60,000-character answer to the Model. The cost caps bind only for a priced
  Model; unknown cost stays unknown.
- **Honest accounting.** Turn Usage merges the exact Engine Usage delta,
  counting each run's real round-trips. The child's native writes join the
  Turn's pending changes. A run still working at Stop is stored as `stopped`.
- **Presentation.** `DeskPilotSubagent` records become `activity` frames of
  kind `agent`; the child's Tool calls nest under the run (`parentId`) and its
  Task List is ignored. The window shows one card per run with Input, Tool
  calls and Output (or the reason), all as text.

## Consequences

- A Subagent is an attenuation boundary, not a sandbox: same process, same
  operating-system identity, same Runspace. It can do nothing its Turn could not.
- Under broader approval, dispatching a Subagent is itself a User Tool call and
  asks once before the run starts.
- A Subagent cannot ask the user; ambiguity is reported in its answer.
- An Engine without the contract keeps the Permission inert
  (`subagentsSupported: false`).

## Rollback

Switch the Permission off; the next Turn does not register `run_subagent`.
Stored runs stay readable. An older DeskPilot rejects the unknown `subagents`
Permission and falls back to default Settings, so remove that key from
`settings.json` before a downgrade.

## Evidence

Red/green Pester cases in `tests/Unit/Subagents.Tests.ps1`, including parity
with the installed Engine's dispatcher (a deliberately dropped
`ToolCallControl` fails it), and an end-to-end run through the real Engine with
a scripted provider: the dispatch and the Subagent's `write_file` both met the
Turn's approval control, the denied write never happened, and the child ran on
the Turn's Model without `run_subagent` or `manage_todo_list`. Nine Node UI cases
and headless Edge renders in dark, light and a 390 px column. No live Model run.

## See also

- [User guide](../../docs/subagents.md)
- [Engine spec 045](https://github.com/raandree/ShellPilot/blob/main/specs/045-bounded-subagents.md)
- [Parallel Agents gate](0005-parallel-agents.md)
- [Turn-wide Terminal approval](0011-turn-wide-terminal-approval.md)
