# Subagents

A **Subagent** is a helper agent that the Model hands one self-contained task
to during a Turn. It works with a fresh context and sends back only its final
report. The parent's context window stays free for the main task, and the
window shows the handoff the way VS Code's chat does: what the Subagent was
asked, the Tool calls it made, and what it reported. This guide covers how to
turn Subagents on, what a Subagent may do, what you see, and the limits.

## Turn it on

Open **Settings → Permissions** and switch on **Subagents**. It ships off:
a Subagent grants nothing new, but every run makes extra Model calls.

Subagents also need:

- **Your tools** on, because `run_subagent` is one of DeskPilot's own User Tools.
- An Engine with the bounded Subagent contract (`Invoke-ShpSubagent` with an
  Invoker). ShellPilot 0.4.0-preview0016 has it. `GET /api/health` reports
  `subagentsSupported`. With an older Engine the Permission does nothing, and
  its row in Settings says so.

## What the Model can dispatch

The Model calls `run_subagent` with:

| Argument | Means |
| --- | --- |
| `prompt` | The complete task. A Subagent does not see the Conversation, so everything it needs goes here. |
| `agent` | Which Subagent to run. Omitted means `general-purpose`. |
| `description` | A 2-5 word label you see on the run, such as `docs audit`. |

The Subagents on offer are:

- **general-purpose**, bundled with DeskPilot, always available unless the
  selected Agent forbids Subagents. A user Agent named `general-purpose`
  replaces it.
- Every Agent in your Agents folder that has a `name` and a `description`, is at
  most 256 KiB, and does **not** set `disable-model-invocation: true`. That flag
  is how an Agent's author says "only a person picks me". It is common in
  existing VS Code Agent files, so many of them are not offered. A name must be
  plain text of up to 64 letters, digits, spaces, dots, dashes or underscores;
  when two Agents share a name, the first file in name order wins.

The selected Agent's `agents:` list narrows the set as it does in VS Code:
absent or `['*']` offers every eligible Agent, a list offers those names, and
`agents: []` offers no Subagent at all. The catalog holds at most 24 entries.

DeskPilot does not interpret an Agent's `tools:` or `model:` lists. They use
VS Code names. A Subagent runs on the Turn's Model with the Turn's Permissions,
as the Agent picker already does for the main Turn.

## What a Subagent may do

A Subagent is a strict subset of the Turn that dispatched it. The Engine's
`Invoke-ShpSubagent` enforces this, and DeskPilot narrows it further:

- It has the Turn's Permissions: every `Disable*` switch the Turn runs under
  applies to it too.
- Every Tool call it makes meets the same approval as the Turn's own would. When
  you enable broader approvals, the Turn's approval control is handed to it as
  the same object. An approval card raised during a run says
  **Asked by Subagent …**.
- It cannot ask you anything, and it cannot start a Subagent of its own.
  DeskPilot withholds `run_subagent` and `ask_questions`, and the Engine refuses
  to run a Tool it did not offer.
- Its Task List is its own and never replaces the Turn's.
- One Subagent runs at a time while the Turn waits. Nothing runs in the
  background, and **Stop** ends a Subagent with the Turn.

A Subagent runs in the same Engine Runspace and process as the Turn, with your
operating-system identity. It is an attenuation boundary, not a sandbox. Files
it writes are part of the Turn's pending changes, so **Keep** and **Undo** work
on them as usual.

With broader approvals on (`approvalCoverage: mutating-tools`), dispatching a
Subagent is itself a User Tool call, so it asks once before the run starts.

## What you see

Each run gets a card above the Turn's thinking and answer:

- **Running agent `general-purpose`…** with the task under **Input**, while the
  Subagent works. The Tool calls it makes appear under **Tool calls** as they
  happen.
- When it ends, the card folds and says **Agent `general-purpose` completed**,
  with the report under **Output**. If it was refused, failed, was cancelled or
  stopped, the card gives the reason instead.
- The line shows the run's duration, its Tool calls and its cost when the Engine
  can price the Model. An unpriced run shows no cost, never `$0.0000`.

The Activity panel lists one **Ran agent** row per run; a run's own Tool calls
are inside its card, not in the panel. Task and report are Model text and are
shown as plain text, never as markup.

## Limits

| Bound | Value |
| --- | --- |
| Subagent runs per Turn | 5 |
| Tool iterations per run | The Turn's `maxToolIterations`, at most 30 |
| Cost per run / per Turn | USD 0.50 / USD 2.00, when the Model is priced |
| Time per run | 900 seconds |
| Task length | 20,000 characters |
| Report returned to the Model | 60,000 characters |
| Task / report kept on the Message | About 8,000 / 20,000 characters |
| A run's Tool calls kept on the Message | 100 |

The cost caps bind only when the Engine has a rate for the Model. For an
unpriced Model the run and iteration caps are the bound. The Turn's Usage
includes every Subagent run, measured from the Engine's own Usage records. A run
is charged what the Engine recorded it spent, so a run cut off at its iteration
cap or deadline still counts towards the Turn's cap.

## Turn it off or roll back

Switch **Subagents** off; the next Turn does not offer `run_subagent`. Stored
runs stay readable. An older DeskPilot rejects the unknown `subagents`
Permission in `settings.json` and falls back to default Settings, so remove that
key before you downgrade.

## See Also

- [Decision 0012: bounded Subagents](../.memory-bank/decisions/0012-bounded-subagents.md)
- [API contract: Subagent runs](../specs/030-api-contract.md#subagent-runs)
- [Isolated child runs](child-agent-isolation.md), a different, contained
  feature
