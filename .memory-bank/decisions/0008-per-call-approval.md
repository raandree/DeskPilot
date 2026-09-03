---
schema-version: 1
status: accepted
owner: software-architect
last-verified: 2026-09-03
source: grill-me interview 2026-09-03, signed off the same day
---

# 0008 — Per-call approval for Terminal commands

Supersedes the "blocked on the Engine" framing this repository carried for
Terminal. See `.memory-bank/topics/design-per-call-approval.md` for the full
Design Concept and `specs/120` for what remains genuinely blocked.

> **Correction, 2026-09-03 — the mechanism below was wrong, and is now fixed.**
> Re-verifying this record against ShellPilot 0.4.0 showed that
> `-DisableTerminal` gated the *offered* tool definition but **not** the
> dispatch switch: `$tc.Name` has a literal `run_command` clause and User Tools
> are reached only through its `default`, so a User Tool registered under that
> name was never invoked and the built-in ran the command ungated. Proved by
> test, not by reading. Resolved the same day in two places — ShellPilot now
> refuses to dispatch a built-in a call did not offer and refuses to register a
> Tool under a built-in's name, and DeskPilot's Tool is now
> `run_terminal_command`. The intent below always stood; only the name and the
> Engine's cooperation were missing.

## Decisions

**DeskPilot owns the terminal Tool; the built-in is removed, not out-voted.**
`Invoke-Shp` is given `-DisableTerminal` whenever approval is active, which
removes the built-in from the offered tool set, and the Engine refuses to
dispatch a built-in it did not offer. The owned Tool is registered as
**`run_terminal_command`** — never `run_command`, because the Engine matches
built-in names before it consults registered Tools, so a same-named Tool is
advertised and then silently bypassed. DeskPilot probes the Engine for the
dispatch refusal at registration and fails loudly without it: an approval gate
that cannot be honoured must not report as active. An owned Tool competing with
a live built-in would be a preference; with the built-in neither offered nor
dispatchable it is a boundary.

**The gate blocks before the executor, and execution is delegated.** The Tool
parks on the approval bridge before it calls anything, so a pending card means
nothing has run. It then hands the command to the Engine's own
`Invoke-RunCommandTool`, so DeskPilot owns the decision and not process
spawning, deadlines, output caps or process-tree kill. Reimplementing those
would have been a second, worse copy of a thing that already works.

**Risk-tiered against an allow-list, not asked on every call.** A gate that
interrupts on `git status` is a gate that gets switched off, and a switched-off
gate protects nothing. A shipped safe-list of read-only commands runs silently;
everything else prompts. The list is an allow-list precisely so its errors land
on the safe side: a deny-list would be wrong forever about everything it had not
heard of, and evaded by `rm -r -f`, an alias or a wrapper.

**A shell operator disqualifies a command before any matching.** `git status;
rm -rf /` opens with an allow-listed prefix. Without this check the allow-list
would authorise everything after the semicolon. Prefix entries match on a token
boundary so `ls` cannot authorise `lsof`, and any entry whose trailing argument
changes its meaning is `exact` — `git branch` lists, `git branch -D main`
destroys.

**No Turn-wide grant.** The grant subsystem built earlier the same day
(`New-DpApprovalState`, `Add-DpApprovalGrant`, `Resolve-DpApprovalGrant`) was
deleted. A class-wide grant silently authorises every later risky command once
one is approved, which is the exact property the gate exists to remove. Two
identical risky commands in one Turn prompt twice.

**The safe-list widens only from Settings.** "Always allow this" beside a prompt
is the button a tired operator presses. Additions live in `safeCommands` and are
validated on merge; a bad entry throws rather than being silently dropped (which
would report as remembered and keep prompting) or silently accepted (which would
be a permanent hole).

**An unanswered request is denied after a timeout, default 15 minutes.** The
Engine has one Runspace, so a parked approval blocks every queued run. Failing
closed costs a retry; failing open costs the boundary.

**The prompt carries facts, never the Model's reasons.** The Model is the party
being checked and its stated justification is attacker-reachable text. A denial
does carry the operator's optional note, so a refusal steers the Agent rather
than dead-ending it.

**Approvals get their own bridge instance.** The rendezvous holds one question at
a time; sharing it with `ask_questions` would let an approval and a question
evict each other, silently, whichever arrived second.

**Both surfaces may answer; groups need a third switch.** The window and the
Intercom private chat receive every request and the first answer wins. A group
chat may answer only under `intercom.groupApproval`, defaulted off and gated by
its own re-confirmation: letting a group instruct DeskPilot and letting a group
authorise a command it was warned about are different amounts of trust.

## Accepted risks

**Unattended runs auto-approve the safe-list, and logging is not a control.** A
scheduled run executes safe-list commands with nobody watching. The diagnostics
entry is an audit trail, not a gate. Bounded by what the safe-list is allowed to
contain, which is why no entry may run repository-controlled code.

**Remote approval is a trust-domain change.** The phone shows the approver less
than the window does. Mitigated by keeping group approval off by default and by
sending the command in full and verbatim.

## Shipped state

`perCallApproval` defaults **off**. Default-on without the browser card would
park a Turn for the full timeout on the first unrecognised command. It flips on
in a later slice.
