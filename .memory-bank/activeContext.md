---
schema-version: 1
status: accepted
owner: shared
last-verified: 2026-09-03
source: repository evidence
---

# Active Context

## Current focus

**The per-call approval boundary does not hold, and isolated execution is blocked
behind it.** Isolated Terminal execution was re-attempted on 2026-09-03. Its
prerequisite gate requires per-call approval to be *implemented and enforced*;
verifying the second half against ShellPilot 0.4.0 disproved it.

`Invoke-Shp -DisableTerminal` removes `run_command` from the tool definitions
offered to the Model, but **not** from the Engine's dispatch switch. That switch
matches `$tc.Name` against literal built-in clauses and reaches registered User
Tools only through its `default`, so DeskPilot's own `run_command` is never
invoked: the built-in matches first and runs the command with no approval card,
no denial path and no bridge. `Register-ShpTool` does not reject the colliding
name, and the offered tool list is not de-duplicated against the built-ins.

Proof (module AST plus line references), the two-step fix, and the refreshed
backend comparison are in `.memory-bank/decisions/0001-isolated-tool-execution.md`.

**Nothing shipped is at risk:** `perCallApproval` defaults off. The defect is the
false promise behind the Setting, and it must not be switched on until fixed.

## Next step

Fix the boundary before anything is built on top of it:

1. Register the owned Terminal Tool under a name that is not a built-in, so it
   lands in the dispatch `default` and actually runs.
2. Close the built-in path with `Set-ShpToolPolicy`, which is evaluated before
   the dispatch switch. Price the side effect: a policy is deny-by-default for
   `Read` and `Write` too, so the intended file reach has to be stated with it.
3. Prove it with a live Turn, not by asserting that a parameter was built.

Isolated execution stays at its architecture decision until then, and needs one
further decision of its own: the Docker/WSL2 dependency is unapproved, and the
development machine currently has no container runtime, no WSL and Windows
Sandbox disabled.

## What shipped earlier (2026-09-03)

Per-call approval was implemented and committed (`3c3048e`, branch
`ai/safety-and-automation`, unpushed): a tiered gate with a shipped read-only
allow-list, a shell-operator disqualifier, no Turn-wide grant, and a dedicated
approval bridge. Gate at the last run: **1656 tests passing, 16 tasks, 0 errors,
0 warnings.** All of that machinery is correct and stays; only the Tool name and
the missing built-in denial keep it from being reached.

New files: `Get-DpSafeCommandList`, `Test-DpCommandSafe`, `Test-DpApprovalActive`,
`Initialize-DpTerminalTool`, `Set-DpTerminalTool`, `Send-DpIntercomApproval`.
Deleted: `New-DpApprovalState`, `Add-DpApprovalGrant`, `Resolve-DpApprovalGrant`.

## Deliberate gaps, not oversights

- **`perCallApproval` ships off.** Now doubly so: default-on would park a Turn on
  the first unrecognised command *and* advertise a gate that is bypassed.
- **There is no Settings UI for `safeCommands` or `approvalTimeoutMinutes`.**
  Both are accepted and validated by the API; neither has a control yet.
- **A pending approval is not yet re-rendered by the SPA on reload.**
  `GET /api/conversations/{id}/approval` serves it, but nothing calls that route
  on load.
- **Intercom denial notes are not collected.** The phone can approve or decline;
  the note field exists only in the window.

## Still genuinely blocked

MCP calls and the Engine built-in File Tools cannot be gated without the upstream
contract in `specs/120`. Terminal was believed to be off that list; it is back on
it in a weaker form — not needing an Engine change, but needing DeskPilot to stop
colliding with the Engine's own dispatch.

## The lesson this session keeps re-teaching

Four inherited claims in this repository have now been measured and found wrong
within three days, and the newest one was written *by this repository, about its
own security boundary, on the day it shipped*. A test that asserts DeskPilot
built a parameter proves nothing about what the Engine does with it. A boundary
is a claim about the other side; it earns the same evidence bar as a bug fix, and
the evidence has to come from the other side. Recorded in `systemPatterns.md`
under anti-patterns.
