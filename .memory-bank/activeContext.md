---
schema-version: 1
status: accepted
owner: shared
last-verified: 2026-09-03
source: repository evidence
---

# Active Context

## Current focus

**Intercom's Something else Keyboard choice now waits for the operator's next
message.** The callback already set `awaitingFreeText`, but the Intercom pump did
not pass that state to `ConvertFrom-DpIntercomUpdate`. A message without
Telegram's explicit Reply metadata was consequently classified as a new prompt
and queued behind the Turn that was waiting for the answer.

The pump now forwards the state. The normalizer accepts the next ordinary
message from the pending question's chat as its answer; another allow-listed chat
still produces a prompt. The acknowledgement now asks the operator to type their
answer in the next message rather than use Telegram's Reply action.

## Evidence

- Red: the tap-then-type pump test expected `answer` and observed `prompt`.
- Green: every `Intercom*.Tests.ps1` test passed, **294/294**.
- Full Sampler: **1660/1663**. The three failures are inherited Terminal approval
  registration tests rejecting installed ShellPilot 0.4.0 after the locally
  staged 0.4.1 fix was removed; none is in an Intercom test.
- All six touched PowerShell files parse. Production PSScriptAnalyzer is clean;
  five existing unused-mock-parameter warnings remain in the two test files.

## Next step

Retry the exact live Telegram sequence: tap **Something else**, type an ordinary
message without invoking Reply, and confirm that the waiting Questionnaire
continues without a queued-Turn acknowledgement.

## Inherited approval work

**ShellPilot** (`D:\Git\ShellPilot`, branch `ai/enforce-disabled-tools`, commit
`70bca37`, unpushed):

- Dispatch refuses any built-in this call did not offer, reusing the existing
  tool-policy denial path so the `tool.call` event, `ToolCallsDenied` and the
  Model's result shape are unchanged. The offered set is derived from the
  assembled tool list, so a tool added later cannot be offered under one
  condition and dispatched under another.
- `Register-ShpTool` refuses a built-in name, the way MCP attachment always has.
- Suite: **1664 passing, 0 failed.**

**DeskPilot** (branch `ai/isolated-execution-gate`):

- The owned Tool is now **`run_terminal_command`**. `ConvertTo-DpActivityAction`
  and `New-DpTranscriptRecord` know the new name; the workspace-tool steering
  text names the terminal capability generically, because which Tool provides it
  now depends on whether approval is active.
- `Initialize-DpTerminalTool` probes the Engine for the dispatch refusal and
  throws without it. A gate that cannot be honoured must not report as active.
- Three Engine-backed registration tests plus one that proves the probe rejects
  a real unfixed Engine. Gate: **1661 tests, 0 failures.**

## Local dependency note

The fix is unreleased. A build of it is staged as
`output/RequiredModules/ShellPilot/0.4.1` - inside DeskPilot's own build output,
which is gitignored and on DeskPilot's module path only. It is deliberately
**not** in the user module path: putting it there made ShellPilot's own suite
import it and fail 779 tests. The installed `0.4.0` stays where it is, and the
capability-probe test asserts against it. Delete the staged folder to undo;
`RequiredModules.psd1` should pin a released ShellPilot once the fix ships.

The registration tests resolve the newest Engine that **has** the fix rather than
the newest Engine, and skip with a stated reason when none is installed. A green
run against an Engine that cannot honour the gate would be worse than a skip.

## Approval work next step

`perCallApproval` still ships **off**, and the reason has changed. It is no
longer "the gate does not hold" - it does now. It is that a Turn parked for the
full 15-minute timeout on someone's first unrecognised command is a poor first
impression, and there is still no Settings UI for `safeCommands` and no SPA
re-render of a pending approval on reload. Flipping the default is a product
decision, separate from this security fix.

Then, in order: a live-Turn proof of approval; optionally `Set-ShpToolPolicy` as
a visible "Project scope" Setting - a real, zero-dependency reach restriction
that must be labelled as scoping and never as isolation; and only then isolation,
which stays blocked on an unapproved Docker/WSL2 dependency that is absent from
this machine.

## Deliberate gaps, not oversights

- **`perCallApproval` ships off**, for the operating-experience reason above.
- **There is no Settings UI for `safeCommands` or `approvalTimeoutMinutes`.**
  Both are accepted and validated by the API; neither has a control yet.
- **A pending approval is not yet re-rendered by the SPA on reload.**
  `GET /api/conversations/{id}/approval` serves it, but nothing calls that route
  on load.
- **Intercom denial notes are not collected.** The phone can approve or decline;
  the note field exists only in the window.

## Still genuinely blocked

MCP calls and the Engine built-in File Tools cannot be gated in place without the
upstream contract in `specs/120`. Terminal is genuinely off that list now.

## The lesson this session keeps re-teaching

Four inherited claims in this repository have now been measured and found wrong
within three days, and the newest one was written *by this repository, about its
own security boundary, on the day it shipped*. A test that asserts DeskPilot
built a parameter proves nothing about what the Engine does with it. A boundary
is a claim about the other side; it earns the same evidence bar as a bug fix, and
the evidence has to come from the other side. The test that found this one
asserts against a real Engine and would have failed on the day the boundary was
written. Recorded in `systemPatterns.md` under anti-patterns.
