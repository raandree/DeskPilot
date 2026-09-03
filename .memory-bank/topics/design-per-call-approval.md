---
schema-version: 1
status: accepted
owner: software-architect
last-verified: 2026-09-03
source: grill-me interview, 2026-09-03
---

# Design Concept: per-call approval for Terminal commands

> Status: **ACCEPTED — signed off 2026-09-03, implemented the same day**
> Interview conducted: 2026-09-03, 25 questions across 8 clusters, all 12 categories.
> Interview depth deviation: the skill's band is 40–100 questions. The gate
> (`Invoke-DpTerminalApprovalTool` and its bridge) was already built and tested
> on 2026-09-03, so Inputs, Outputs, Performance and parts of Security were
> confirmations rather than discovery. Recorded rather than padded.
> Override log: none. The one objection raised (group approval) was answered by
> the operator moving to a narrower option, not by overriding.

## Purpose

Stop a destructive Terminal command **before it runs**, in a way that survives
contact with daily use.

The interview opened with a contradiction worth preserving in the record. The
stated purpose was "safety gate"; the stated expectation was that "the feature
will not be used much and most people will turn it off … just having it is good
on the product description"; the stated kill-reason was "too many prompts for
routine, harmless commands". A safety control that is expected to be disabled
and is nonetheless listed as a feature is security theatre, and it is worse than
absent because it changes how much a reader trusts what it does not guard.

The operator resolved this by choosing to design a control that actually stays
on. Every decision below follows from that choice, and the design is only
honest if the prompt rate stays low enough that approvals remain deliberate.

## Scope

- **Terminal commands only.** DeskPilot registers its own `run_command` User
  Tool and always passes `Invoke-Shp -DisableTerminal`, so the built-in is absent
  from both the offered tool set and the dispatch switch and the Model has
  nothing to fall back to.
- **Risk-tiered.** A command matching the shipped safe-list runs without a
  prompt. Everything else prompts. The tier fails closed: unrecognised means ask.
- **Allow-once only.** There is no Turn-wide grant.
- **On by default**, taking effect only for users who have deliberately enabled
  the Terminal Permission, which remains off by default.

## Non-goals

Proposed by the architect; the operator skipped this question and may strike any
line during sign-off.

| Not built | Why |
| --- | --- |
| MCP call approval | The Engine dispatches MCP itself, `-DisableMcp` is all-or-nothing, annotations never reach the host. Needs `specs/120`. |
| Out-of-Project file-write approval | `-DisableFileAccess` removes `read_file` and `list_directory` with `write_file`, so gating writes means owning reads too. Separate decision. |
| A policy editor or rules engine | The safe-list is a small reviewed list. A rules engine is a different product. |
| Model-rated risk | A prompt-injected Agent deciding whether it needs approval is the confused-deputy problem. Refused on principle, not deferred. |
| Approval for Browsing or File Tools | Different classes, different risk profile. |
| A durable on-disk approval log | The purpose is safety, not audit. A permanent record of every command is itself sensitive and needs its own retention and redaction design. |

## Stakeholders

| Role | Who | Notes |
| --- | --- | --- |
| Triggers | The Agent, mid-Turn | Never the user directly |
| Answers | The operator, at the DeskPilot window **or** in the Intercom private chat | First answer wins |
| Answers (optional) | A member of an allow-listed Telegram group | Only behind a separate switch, default off — see Security |
| Owns the safe-list | The operator, via Settings only | Never widened from the approval prompt itself |
| Bears the cost | The operator, in interruptions | The prompt rate is the product risk |

## Inputs

The approval request is built from an **allow-list**, not a copy of the Tool
arguments, because arguments are exactly where a token or a file body would be.

| Field | Source | Shown |
| --- | --- | --- |
| `command` | Tool argument, bounded at 2000 chars with a truncation marker | Yes |
| `workingDirectory` | Tool argument, or the Turn's Project | Yes |
| `project` | Turn context | Yes |
| `risk` | Fixed text per class | Yes |
| `fingerprint` | SHA-256 over tool, class, Conversation, Turn, command, working directory | No — correlation only |
| Anything else the Model supplied | — | **Never carried** |

The Model's stated reason for the command is **deliberately not shown**. It is
attacker-controlled text in an injection scenario and would render beside a real
command with equal authority; no labelling makes that safe to rely on.

## Outputs

| Answer | Effect | What the Agent receives |
| --- | --- | --- |
| Approve | The command runs, delegated to the Engine's own `Invoke-RunCommandTool` | The command's normal result |
| Deny | Nothing runs | A structured Tool result stating the user declined, plus the operator's **optional free-text note** so a denial can steer rather than dead-end |
| Timeout | Nothing runs | Same shape as deny, stating that it expired |
| Stop | Nothing runs | Same shape, stating the Turn was stopped |

A denial is never a failed Turn.

## Quantified requirements

| Requirement | Scale | Meter | Target |
| --- | --- | --- | --- |
| Prompt rate | Prompts per Turn whose commands are all on the safe-list | Unit test over a representative command set | **0** |
| Prompt rate, mixed Turn | Median prompts per Turn, real use | Diagnostics log count over one week | **≤ 3** (Fail: > 3 sustained) |
| Fail-closed classification | Commands executed without a prompt that are not an exact safe-list match | Unit test | **0** |
| Unshown execution | Commands executed under authority the operator was not shown | Unit test | **0** — guaranteed structurally once the Turn grant is removed |
| Answer latency | Wall-clock from prompt to answerable in the window | Manual check | **< 1 s** |
| Engine block | Minutes a parked approval may hold the Engine Runspace | Setting | **15 by default**, configurable |

## Design options and recommendation

Each row records the decision, the alternative that lost, and why.

| Decision | Chosen | Rejected | Why |
| --- | --- | --- | --- |
| Gate mechanism | DeskPilot owns `run_command`; `-DisableTerminal` removes the built-in | Wait for an Engine `ToolCallApprover` contract | The Engine already supports removing its terminal tool; an owned Tool with no built-in rival is a boundary, not a preference |
| Execution | Delegate to the Engine's `Invoke-RunCommandTool` | Re-implement process spawning | Deadlines, output caps, encoding and tree-kill are where the real risk lives; the Engine already does them carefully |
| Prompt frequency | Risk-tiered on a safe-list | Ask for every command | Ask-always was chosen first, then reversed: at 4–10 commands per Turn it produces exactly the fatigue named as the kill-reason, and a reflexive approval is worth nothing |
| Classifier | Allow-list of known-safe commands | Deny-list of dangerous patterns | A deny-list fails **open** — wrong forever about everything it has not heard of, and evaded by `rm -r -f`, an alias or a wrapper |
| Turn-wide grant | **None** | Class-wide, per-executable, per-command | With tiering, only risky commands prompt; a class-wide grant would then silently authorise every *later risky* command. Tiering removed the volume problem the valve existed for |
| Safe-list ownership | Shipped list, additions only from Settings | Editable from the approval prompt | "Add to safe list" beside a prompt is the button a fatigued user mashes. The widening decision must be made cold |
| Who may answer | Window **and** Intercom private chat | Window only | Accepted cost: the full command text reaches Telegram |
| Group approval | Own switch, default off, with `confirm_group_projects`-style re-confirmation | Allowed outright | Objected to on the record; the operator moved to the narrower option |
| Unattended runs | Safe-list commands run; the rest are refused, and every auto-approval is logged | Stricter read-only subset | Accepted risk: the safe-list gains unattended authority with no human backstop, mitigated only by logging — and logging is not a control |
| Default state | **On** | Off, or offered when Terminal is enabled | Terminal is already off by default, so the affected population is exactly those who opted in. "Terminal" now means "terminal, with approval" |
| Reload | Pending approval is re-delivered on reconnect | Park until Stop; auto-deny on disconnect | A stray Ctrl+F5 must not cost the Turn, and must not silently deny |

## Failure modes

| Failure | Behaviour |
| --- | --- |
| Nobody answers | Denied after the configured timeout (default 15 min). Fails closed and frees the Engine |
| Browser refreshed or reopened | The pending approval is re-delivered; the Turn is never stranded by a reload |
| Stop while pending | The wait is cancelled, nothing runs, the Agent gets a recoverable result |
| Approval bridge inactive | Refused without running anything |
| Executor missing | Refused without running anything |
| Command approved but fails to start | Reported as a Tool error, not as an approval failure |
| Safe-list corrupt or unreadable | Treated as empty — everything prompts. Fails closed |

## Edge cases

- **Two approvals at once.** Serialised. The approval bridge is separate from the
  Ask-User bridge so an answer to one can never satisfy the other, and a pending
  question never blocks a pending command.
- **Window and phone both answer.** First answer wins, matching the bridge's
  existing `SubmitAnswer` semantics. A simultaneous approve/deny is a coin flip;
  accepted, because a settle window would slow every approval to guard a rare race.
- **Answer arrives after the timeout.** Rejected — the request no longer exists.
- **The same command twice in one Turn.** Prompts twice. There is no grant.
- **Command longer than 2000 characters.** Truncated in the summary with an
  explicit marker; the fingerprint covers the full text.
- **Terminal Permission switched off mid-Turn.** Authority never changes
  mid-Turn; it takes effect on the next Turn.

## Security

- **The boundary is the absent built-in.** Without `-DisableTerminal` the owned
  Tool is a suggestion. The pairing is the control and must be tested as one.
- **The gate precedes the effect.** The Tool blocks before it calls the executor,
  so a pending prompt means nothing has run. Proven by a cross-runspace test that
  asserts the side effect is absent while the prompt is outstanding.
- **The summary is an allow-list.** Tested against a request carrying a
  token-shaped argument and a secret-bearing environment map.
- **An answer is bound to one action.** Fingerprint over tool, class,
  Conversation, Turn, command and working directory; a stale, replayed or
  cross-Conversation answer authorises nothing.
- **The safe-list is a security boundary.** It fails closed by construction
  (unknown means ask) and may be widened only from Settings, never from the
  prompt. Each shipped entry needs review; a wrong entry is a permanent hole.
- **Remote approval is a trust-domain change.** The command text leaves the
  machine and rests on Telegram's servers; approval authority then depends on a
  bot token rather than the loopback session token. Accepted deliberately.
- **Group approval is a second, larger trust-domain change.** Telegram controls
  the membership list. Behind its own default-off switch with explicit
  re-confirmation naming what it covers, following the pattern already
  established for `allowGroupChat`.
- **Unattended auto-approval has no backstop.** Accepted risk, mitigated by
  logging only.

## Performance

Human-speed and local; there is no throughput question. The only real cost is
that a parked approval holds the single Engine Runspace, so scheduled runs, file
triggers and Intercom prompts queue behind it. Accepted: the timeout bounds the
damage to the configured window. A scheduled run may consequently record
`missed` because the operator was slow to answer; that is a known and accepted
interaction.

## Observability

- An **Activity row per decision** — requested, approved, denied, expired — with
  the command, beside the rest of the Turn's actions.
- A **diagnostics log entry**, already redacted, bounded and exportable in a
  support bundle.
- Unattended auto-approvals are logged explicitly.
- No durable on-disk approval log. The purpose is safety, not audit.

## Rollback

- The Setting takes effect on the **next** Turn. Authority never changes
  mid-Turn.
- A Turn already parked on an approval is escaped with **Stop**, not by flipping
  the Setting. This must be documented where the Setting lives.
- Switching approval off never retroactively approves or denies a pending
  request.
- Rolling the feature back entirely means clearing one Setting; the owned Tool is
  simply not registered and `-DisableTerminal` is not passed, restoring today's
  behaviour exactly.

## Consequences for code already written

The interview invalidated part of yesterday's build. Recorded here so sign-off
covers the deletion as well as the addition.

| Artefact | Fate |
| --- | --- |
| `Invoke-DpTerminalApprovalTool` | Kept; loses the `turn` scope branch, gains the safe-list check and the timeout |
| `New-DpApprovalRequest` | Kept unchanged |
| `New-DpApprovalState`, `Add-DpApprovalGrant`, `Resolve-DpApprovalGrant` | **Deleted.** `once` never stored anything; the grant store existed solely for the Turn grant. Dead code in a security control is a liability |
| `perCallApproval` Setting | Kept; default flips to `$true` |
| Grant tests in `TerminalApproval.Tests.ps1` | Deleted with the functions; the blocking, denial and allow-list proofs stay |

New work: the safe-list and its matcher, the approval SSE frame and route,
re-delivery on reconnect, the timeout, the approval card, the Intercom delivery
path, the group switch, the Activity and diagnostics records.

## Acceptance criteria

1. With `perCallApproval` on, `Invoke-Shp` receives `-DisableTerminal` on every
   Turn, and a test asserts the built-in `run_command` is absent from the tool
   set offered to the Model.
2. A command that exactly matches a safe-list entry runs with **no** prompt.
3. A command that does not match runs **only** after an approval whose
   fingerprint equals that command's; the side effect is provably absent while
   the prompt is outstanding.
4. An unrecognised command prompts. A corrupt or empty safe-list prompts for
   everything.
5. Denial produces a Tool result the Agent can act on, carries the operator's
   optional note, and does not fail the Turn.
6. An unanswered approval is denied after the configured timeout and the Engine
   Runspace is released.
7. A browser reload re-delivers the pending approval; the Turn is not stranded
   and is not silently denied.
8. Stop cancels a pending approval and nothing runs.
9. A late, replayed or cross-Conversation answer authorises nothing.
10. No Turn-wide grant exists: two identical risky commands in one Turn prompt
    twice.
11. Approval is never reachable from a group chat unless the separate switch is
    on, and switching it on requires a re-confirmation naming what it covers.
12. An unattended run executes safe-list commands, refuses the rest, and logs
    every auto-approval.
13. Secret-shaped Tool arguments never appear in the prompt, the Activity row,
    the diagnostics log or a support bundle.

## Open questions

Proposed by the architect; the operator skipped this question, so each is an
open `TBD` rather than a settled point.

| TBD | Owner | Blocking? |
| --- | --- | --- |
| The initial contents of the shipped safe-list | Operator + architect | **Yes** — the prompt rate, and therefore the whole design, depends on it |
| Whether 15 minutes is the right default timeout | Operator | No — configurable |
| How the safe-list grows without becoming a hole (review process) | Operator | No, but it decides whether the control degrades over time |
| Whether the group-approval switch is ever worth shipping | Operator | No — default off |
| Whether a stricter unattended subset should replace "same list + logging" | Operator | No — recorded as an accepted risk |

## Sign-off

- [x] Operator has read this document end to end.
- [x] Operator accepts every section, or has flagged required changes.
- [x] Operator accepts the deletion of the grant subsystem built on 2026-09-03.
- [x] Operator accepts the two recorded risks: remote approval as a trust-domain
      change, and unattended auto-approval with logging as its only mitigation.
- [x] Operator signed off on 2026-09-03 and asked for the specs and the
      implementation in the same instruction.

### Implementation deviations, announced at the time

1. **`perCallApproval` ships off**, not on. Default-on without the card would
   have parked a Turn for 15 minutes on the first unrecognised command. It flips
   on in a later slice, once the browser surface has been used in anger.
2. **The blocking safe-list TBD was decided rather than left open**, because the
   whole risk-tiering decision rests on it. The shipped list is read-only `git`
   subcommands, PowerShell readers, `ls`/`dir`/`cat`/`head`/`tail`/`wc`, `pwd`
   and fixed `--version` probes. `npm test`, `dotnet run` and `find` are
   deliberately excluded, and a test asserts no entry gives an interpreter or
   package runner a prefix entry.
