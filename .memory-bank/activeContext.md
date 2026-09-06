---
schema-version: 1
status: accepted
owner: shared
last-verified: 2026-09-06
source: local Git history and verified Sampler test and build outputs
---

# Active context

## Current focus

Consolidate the reviewed local feature Branches into `main`, retain their useful
changes, and remove their local Branch names after verified Merge. The five
Branches form one fast-forward chain with eight commits beyond `2eb4975`.
The integration Branch is `ai/integrate-feature-branches`; no remote mutation
or publication is authorized.

| Branch | Retained tip | Contribution |
| --- | --- | --- |
| `ai/isolation-dependency-decision` | `9d8211b` | Optional Terminal isolation, dependency evidence, and operator documentation |
| `ai/parallel-agents-prerequisite-plan` | `293d5a5` | Parallel-Agent prerequisite decision and dependency plan |
| `ai/child-agent-isolation-prompt` | `2d86925` | Single-child implementation Prompt File and acceptance cases |
| `ai/child-agent-isolation` | `275cd6b` | Guarded private Tool storage and its component tests |
| `ai/parallel-agents-prerequisite-gate` | `31f2d07` | Reassessed parallel-Agent gate with child startup still unavailable |

All eleven initially modified files matched their index blobs after Git content
normalization. Refreshing those exact index entries cleared the flags without
rewriting files, discarding code, or creating an empty commit. A fresh origin
fetch found no additional work. `origin/ai/safety-and-automation` was already an
ancestor of `main`; remote Branches remain untouched.

## Fresh verification

- `build.ps1 -Tasks test`: **2,373 passed, zero failures, five existing browser
  Unicode skips, zero unrun cases**. PowerShell 7.6.5, Pester 6.1.0; nine tasks,
  zero errors/warnings, completed 2026-09-06 13:29:28 UTC. Includes the actual
  child-storage and Terminal-container integration suites.
- `node --test tests/Unit/terminal-isolation-ui.test.mjs`: **3 passed**.
- `node tests/live/terminal-isolation-ui.mjs`: passed at **1440px and 390px**;
  screenshots reviewed, no horizontal overflow or overlapping controls.
- Tests preceded `build.ps1 -Tasks build`: **seven tasks, zero errors/warnings**,
  completed 13:31:13 UTC. Built version `0.0.1` imports successfully and exports
  `Start-DeskPilot`. All **34 bundled assets** match their source hashes.
- Built defaults remain Local and child execution disabled; readiness is false.
  Independent Docker inspection found no child or Terminal containers left.
- Integrated diff whitespace check passed. Runtime and tests are unchanged from
  `31f2d07`; the consolidation record changes only Memory Bank files.

Logs and copied test reports are retained under `$env:TEMP`:

- `deskpilot-integrated-tests-be2392aed20d466db73c980d2cd73d2b.log`.
- `deskpilot-integrated-tests-be2392aed20d466db73c980d2cd73d2b.-evidence`.
- `deskpilot-integrated-build-db74317bde79463d9de4ce78c8976362.log`.
- `deskpilot-terminal-ui-DIhsrm` contains the desktop/mobile screenshots.

## Release boundaries remain unchanged

The [single-child V2 prerequisite](decisions/0009-single-child-isolation.md)
remains partial. Private Tool storage, baseline capture, authenticated IPC,
bounded export, lease, Stop/recovery, retention admission, and refusal exist.
Complete Engine request admission, credentialless child Engine/transport,
child approvals/accounting, and restart/retention integration remain open.
The prior credential-filter correction still needs independent re-review;
the two Major integration/admission gates and retention/restart Minor remain.
No child Engine, recursive delegation, or parallel scheduling is enabled.

[Decision 0005](decisions/0005-parallel-agents.md) still requires operator
approval of the two-child topology. Its public-evidence profile needs a separate
approved retrieval boundary. Recommend `review: on` before enabling or releasing
child execution; this consolidation is not an independent security review.

Optional Terminal isolation retains the limitations in
[decision 0001](decisions/0001-isolated-tool-execution.md) and the
[operator guide](../docs/isolated-terminal.md). Live authenticated acceptance
and an obtainable dispatch-enforcing Engine remain separate release gates.
No Model call, authentication change, or production Settings change occurred.

The separate Engine worktree `D:/Git/ShellPilot-child-isolation` remains on
`ai/child-provider-boundary`. The original ShellPilot worktree and its unrelated
modified test on `ai/edit-file-tool` were outside this task and remain untouched.
