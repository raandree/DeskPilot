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

## Why per-call approval is not here

`implement-per-call-approval.prompt.md` stays in the active folder. Its objective
names three surfaces — Terminal commands, file writes outside the Project, and
mutating MCP calls — and only Terminal has shipped (decision 0008). The other two
need the Engine contract in [`specs/120`](../../../specs/120-per-call-approval-engine-contract.md).

It also asks for an `Allow for this Turn` option that was deliberately **not**
built: the signed-off design removed Turn-wide grants because one approval would
silently authorise every later command of that class. That deviation is recorded
in decision 0008, not left to be rediscovered from the diff.
