# Archived Prompt Files

Prompt Files whose objective has been met. They are kept for provenance — each
one is the brief the shipped feature was built against — and they are **not part
of the active sequence**. Do not invoke one against the current tip: the work is
already in the codebase, and re-running it would either no-op or duplicate.

Move a file back to `../` only if its feature is materially reopened.

| Prompt | Shipped as | Evidence |
| --- | --- | --- |
| [Diagnostics and support bundle](implement-diagnostics-support-bundle.prompt.md) | Diagnostics panel, bounded live log, Model-free self-check, redacted support bundle | `Invoke-DpDiagnosticCheck`, `New-DpDiagnosticLog`, `New-DpSupportBundleRecord`, [docs](../../../docs/diagnostics-support-bundle.md) |
| [Scheduled work](implement-scheduled-work.prompt.md) | Persistent daily/weekly/one-time schedules on the single-active-Turn dispatcher | `ConvertTo-DpSchedule`, `Update-DpScheduleState`, `Invoke-DpScheduledTurn` |
| [Condition-triggered automation](implement-event-triggered-automation.prompt.md) | File-arrival triggers sharing the schedule queue, locked to `safe` mode | `Get-DpAutomationEvent`, decision 0004 |
| [Windows packaging](implement-windows-packaging.prompt.md) | CurrentUser package with install, launch, update and uninstall | `packaging/`, decision 0006 |
| [Localization](implement-localization.prompt.md) | Build-free ES-module catalogs, English source, German shipped | `source/web/assets/locales/`, decision 0007 |
| [Fix the Intercom group-chat findings](fix-intercom-group-findings.prompt.md) | All seven assessment findings closed | [assessment log](../../../.memory-bank/assessment-log.md) |
| [Playwright browser automation](implement-browser-automation.prompt.md) | Contained browser behind its own Permission: one workflow, scope from the user's own message, per-Project write capabilities each approved per action | `source/browser/`, `Invoke-DpBrowserTool`, decision 0003, [hostile-site proof](../../../tests/live/Invoke-DpBrowserHostileTest.ps1) |

## Why the browser prompt shipped without decision 0001's isolation

The Prompt File requires "shipped isolated execution", and 0001's isolation -
container confinement for terminal commands - is still blocked. Decision 0003
scopes that prerequisite out deliberately rather than by omission: browser
automation carries its own boundary, a separate supervised process with a
disposable profile that has no cookies, extensions, password store, history or
ambient SSO, and that is what makes "Stop kills the whole tree" implementable.

The scoping authorises a browser-only Tool surface. It is **not** a precedent for
calling process separation "isolation" for terminal commands, and it leaves
parallel Agents (0005) blocked exactly where it was.

## What the browser prompt cost, for whoever writes the next one

Five independent security review rounds, ten Blockers. After the first round,
every round's Blockers were inside the previous round's fixes, and four of them
were defended by a comment stating a guarantee the code did not provide. The
review loop only stopped being a treadmill when the work shifted from adding
controls to measuring whether the tests for them could fail - see the exit
criterion and standing rules in decision 0003, and the two mutation matrices under
`tests/Unit/fixtures/`.

## Why per-call approval is not here

`implement-per-call-approval.prompt.md` stays in the active folder. Its objective
names three surfaces — Terminal commands, file writes outside the Project, and
mutating MCP calls — and only Terminal has shipped (decision 0008). The other two
need the Engine contract in [`specs/120`](../../../specs/120-per-call-approval-engine-contract.md).

It also asks for an `Allow for this Turn` option that was deliberately **not**
built: the signed-off design removed Turn-wide grants because one approval would
silently authorise every later command of that class. That deviation is recorded
in decision 0008, not left to be rediscovered from the diff.
