---
schema-version: 1
status: accepted
owner: shared
last-verified: 2026-09-03
source: repository evidence
---

# Active Context

## Current focus

**Parallel Agents stopped at its prerequisite gate again, and the Engine's one
concurrency contract was measured rather than assumed.** Per-call approval is
now implemented *and* enforced, but only against a locally built ShellPilot
0.4.1; the newest published build is 0.4.0, which fails the capability probe.
Isolation is still absent from `source/` entirely. One half open is not the gate
open, so no concurrency was added.

The new finding is `Invoke-ShpBatch`. The Engine does have a bounded fan-out
with merged Usage and a per-item result envelope, and it is structurally unable
to carry a DeskPilot child: it forces `DisableUserPrompts` (so the approval
bridge is unreachable, not merely absent), `DisableProgressEvents` (no Activity,
no Thinking), `DisableStreaming` and `History = @()`, and it replays registered
Tools by command name into a runspace that inherited nothing — which drops every
DeskPilot Tool, because all of them are injected with `AddScript`. A batch child
would therefore keep the built-in `run_command` and lose the gated
`run_terminal_command`: the bypass fixed this morning, reached by a different
route.

## Evidence

- `subagent`, `sub-agent`, `child agent`, `delegat`: **0 occurrences** in both
  ShellPilot 0.4.0 and 0.4.1.
- `Invoke-ShpBatch` is exported; `Invoke-ShpParallel` is private.
  `-ThrottleLimit` is `ValidateRange(1, 64)`, default 4.
- Forced per item at lines 12637-12639 of `ShellPilot.psm1`:
  `DisableStreaming`, `DisableUserPrompts`, `DisableProgressEvents`.
- `Invoke-ShpBatchItem` catches a tool it cannot re-register and warns; the
  Engine's own comment names the cause as a function that "exists only in the
  caller's session".
- `source/` matches for container, sandbox, isolation or worktree: an MCP
  `sandboxRequested` badge and the browser's `<iframe sandbox>`. Nothing else.
- Installed Engine: **0.4.0**. Locally staged: `output/RequiredModules/ShellPilot/0.4.1`.

## Next step

Unchanged and unchanged in order: publish the Engine fix, then decide the
isolation dependency. Decision 0005 now also names a third prerequisite — a child
Runspace factory that carries DeskPilot's own Tools and its own approval bridge,
or holds neither Terminal nor File write.

## Previous focus

**Intercom's Something else Keyboard choice now waits for the operator's next
message.** The callback already set `awaitingFreeText`, but the Intercom pump did
not pass that state to `ConvertFrom-DpIntercomUpdate`. A message without
Telegram's explicit Reply metadata was consequently classified as a new prompt
and queued behind the Turn that was waiting for the answer.

The pump now forwards the state. The normalizer accepts the next ordinary
message from the pending question's chat as its answer; another allow-listed chat
still produces a prompt. The acknowledgement now asks the operator to type their
answer in the next message rather than use Telegram's Reply action.

Its live retry is still outstanding: tap **Something else**, type an ordinary
message without invoking Reply, and confirm that the waiting Questionnaire
continues without a queued-Turn acknowledgement.

## Intercom evidence

- Red: the tap-then-type pump test expected `answer` and observed `prompt`.
- Green: every `Intercom*.Tests.ps1` test passed, **294/294**.
- Full Sampler: **1660/1663**. The three failures are inherited Terminal approval
  registration tests rejecting installed ShellPilot 0.4.0 after the locally
  staged 0.4.1 fix was removed; none is in an Intercom test.
- All six touched PowerShell files parse. Production PSScriptAnalyzer is clean;
  five existing unused-mock-parameter warnings remain in the two test files.

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
