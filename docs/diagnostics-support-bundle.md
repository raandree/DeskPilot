# Diagnostics and Support Bundle

Diagnostics turns local Host Server state into a short health report and a
shareable, redacted support archive. It is intended for users diagnosing a
missing Engine, Project, MCP server, Intercom connection, or Update result.

## Open Diagnostics

Open **Diagnostics** from the sidebar footer or choose **Open diagnostics** in
the command palette.

The view reports:

- DeskPilot, PowerShell, Engine, Git, and operating-system versions
- the resolved DeskPilot data and Engine module paths
- the active Project
- Engine loading and authentication state
- MCP server, Intercom, and Update state
- the most recent self-check time and result
- recent redacted Host Server events

The two resolved paths are absolute because confirming those exact local paths
is part of diagnosis. They appear only in the local, session-token-protected
view. The support bundle keeps their purpose and leaf name instead.

## Read a state

Every check uses one of four states:

| State | Meaning |
| --- | --- |
| **Healthy** | The dependency was inspected and is ready. |
| **Needs attention** | It was inspected, but a problem or timeout was found. |
| **Unavailable** | It could not be inspected or is missing. |
| **Not configured** | The optional dependency or Project is not enabled. |

Each result has a bounded explanation and at most one safe **Next:** action.
DeskPilot never reports success when inspection was unavailable.

## Run the self-check

Select **Run self-check**. DeskPilot starts a background, deterministic check
and keeps the Host Server responsive while it runs.

The self-check:

- validates configuration shape and local paths
- checks the local Git executable and version
- reads allow-listed Engine authentication, MCP, Intercom, and Update state
- gives every active local probe a 1.5-second deadline

It does not call a Model or the Engine, make a network request, mutate user data,
start a Tool, or consume Copilot credits. A failed or slow probe is reported as
**Needs attention** rather than success.

## Read or clear the Host Server log

The log is an in-memory ring owned by the current Host Server process. It keeps
at most 500 entries and 1 MiB. Each entry contains only:

- timestamp
- severity
- component
- event id
- redacted summary

The browser requests only entries newer than its last sequence every two
seconds, and only while Diagnostics is open. Closing the view stops polling.

Select **Clear log** to empty the ring. Restarting DeskPilot also clears it. The
log is never silently persisted.

## Create a support bundle

Select **Create support bundle**. DeskPilot creates one new ZIP in
`<DeskPilot data>/support-bundles` and displays the exact destination.
Nothing is uploaded automatically.

The archive contains exactly:

- `summary.md` — a human-readable version and health summary
- `diagnostics.json` — structured, allow-listed diagnostic data
- `host-log.jsonl` — redacted Host Server events

Configuration is represented by shape, counts, Permission and feature enabled
states, and MCP/Intercom configured-state metadata. Unknown fields are excluded
instead of copied and cleaned afterward.

The bundle never includes:

- prompts, answers, reasoning, or Message history
- file contents, diffs, Attachments, or raw Tool arguments
- tokens, cookies, authorization headers, or credentialed URLs
- environment-variable values
- absolute data, Engine module, Project, or user-profile paths

The uncompressed generated text is capped at 2 MiB and the ZIP at 3 MiB.
DeskPilot chooses a collision-safe name, never overwrites an archive, and
refuses traversal, reparse-point redirection, or a concurrent export.

## See also

- [API contract](../specs/030-api-contract.md#diagnostics)
- [Security model](../specs/050-security-model.md#diagnostics-and-support-bundle)
- [Architecture](../specs/020-architecture.md#diagnostics-and-support-bundles)
