# Child Agent isolation prerequisite

This guide preserves the strict V2 prerequisite and historical counting
investigation. The later accepted estimated-budget profile is implemented and
documented in [Single-child V3](single-child-v3.md). Its separate proof and
opt-in requirements do not reinterpret V2 or enable parallel Agents.

## Historical V2 status and approval

The operator approved revised design V2 on 2026-09-06. It calls for a
credentialless child Engine container, a separate Tool container, and trusted
Engine-owned provider transport, integrated through the Host Server. Approval
also covers limited tracked ShellPilot contract changes, not publication.

Only part of that design is implemented. Ordinary Turns and their defaults are
unchanged. `childExecution.enabled` defaults to `false`; changing it cannot
bypass the readiness gate. No child start, approval, or proposal UI is enabled.

| Gate | Current status |
| --- | --- |
| Design approval | V2 approved; decision 0005's two-child proposal remains unapproved. |
| Private Tool storage and lifecycle | Implemented and exercised against Docker Desktop/WSL2. |
| Deterministic checks | Policy, startup refusal, Windows capture, and authenticated IPC checks exist. |
| Actual-runtime checks | File/Terminal work, byte/inode quotas, read-only denial, export, Stop, lease, owner death, and reconciliation checks exist. |
| Complete child Engine process and approval bridge | Not integrated. |
| Aggregate Engine Usage, context, and resource bounds | Not implemented or proven across the complete V2 run. |
| Authenticated live proof | Counting probes and four capped Engine requests succeeded; the complete child profile and its hard request bound remain unproven. |
| Clean-install Engine support | Not proven; local Engine changes are not a released dependency. |
| Independent security review | Request changes: three Majors and one Minor. One implemented Major is author-corrected; the two Major integration/admission gates and retention/restart Minor remain open. |

The final checked-in proof after the review correction passed 87 tests without
failures or skips: 68 deterministic checks and 19 real-container checks. These
are component proofs, not proof of a complete child Agent. Source-bound evidence
is retained by the launcher and recorded in the decision.

The final full DeskPilot gate passed 2,373 tests, with no failures and five
existing browser skips. The separate Engine full gate passed 1,749 tests with
no failures/skips and 88.79% coverage. Both builds completed 16 tasks with zero
errors or warnings. These results do not close the missing profile contracts.

## Engine blocker

The inspected ShellPilot exposes a heuristic token estimate and a cost guard
that runs after a completed request. Deterministic provider fixtures reproduced:

- A priced zero-dollar budget still dispatches once, then reports USD 0.00208.
- A one-token context budget dispatches despite an approximately 535-token
  estimate.
- An API-shape error resends with `MaxRetryCount = 0` and reports one iteration
  for two requests.

Limited tracked Engine changes now add `NoAutomaticRetry` and a credentialless
`RequestTransport` callback. They are tested locally, not installed over the
ignored dependency or published. The 2026-09-06 continuation also implements
conditional `RequestLimits` and `RequestTokenCounter`: a trusted count can be
reserved with maximum output and Engine-priced cost before dispatch. Failed or
unknown Usage retains its reservation and stays explicitly unknown. The 38
public and seven helper tests use identified deterministic counters; they do not
supply a verified Copilot complete-request bound or trusted transport process.

The missing admission contract must cover all submitted messages, system text,
Tool schemas, maximum output, Model-specific framing and pricing, failed or
unknown Usage, cancellation, and every resend before dispatch. Character
estimates or a tokenizer for text alone are insufficient. The
[OpenAI counting guide](https://developers.openai.com/cookbook/examples/how_to_count_tokens_with_tiktoken)
expressly describes its chat counts as estimates and notes additional Tool
overhead; it is not a Copilot complete-request bound.

Do not substitute completed spend, a locally scripted response, a caller's
unverified count, or a provider hostname allow-list for this contract. Until a
supported bound is verified, full child startup must remain unavailable.

On 2026-09-06 the operator chose **Keep V2 unchanged; close out verified
groundwork** after this counting gap was confirmed. No estimated-count fallback
was approved. The remaining complete child Engine, approval bridge, whole-run
limits, restart/retention integration, authenticated live proof, and complete
profile security review remain open. The admission extension is not a readiness
claim, a release, or approval of parallel Agents.

The admission continuation passed the full Engine gate (1,810 tests, no failures
or skips, 89.12% coverage) and the unchanged DeskPilot gate (2,373 passed, five
existing browser skips). Both completed 16 tasks without errors or warnings.
Independent review approved the admission diff with no Blocker or Major; its
one Minor test gap was closed with two additional parameter-guard cases. This
approval covers admission groundwork, not the complete child profile or the
earlier child-storage credential-filter correction.

### Live counting investigation

The operator refreshed Engine sign-in on 2026-09-06. `Get-ShpModel -Endpoint
Session` then returned 43 Models at 21:19 UTC. This resolves the earlier local
DPAPI decryption failure; authentication is no longer the counting blocker.

The Engine-selected host was `api.enterprise.githubcopilot.com`. Read-only
discovery and non-generating count probes returned:

| Operation | Requested Model | Result |
| --- | --- | --- |
| `GET /models` | Not applicable | 200; 43 Models, using the same HTTP client as the Messages probe. |
| `POST /responses/input_tokens` | `gpt-5-mini` | 404; no count returned. |
| `POST /v1/messages/count_tokens` | `claude-haiku-4.5` | 200; input-token count returned. |

The hosted Claude counter was then compared with the Engine's existing
`Invoke-CopilotTurn` Chat transport, using equivalent non-sensitive Messages
and Chat inputs. Generation was capped at eight output tokens per request,
with no automatic retries or Tool execution.

| Fixture | Hosted Messages count | Engine-reported input | Difference |
| --- | ---: | ---: | ---: |
| Plain text | 11 | 11 | 0 |
| System text | 31 | 31 | 0 |
| Tool schema | 587 | 580 | +7 |
| Tool result | 669 | 662 | +7 |

A count-only variant removed explicit `tool_choice` and returned the same four
counts, ruling out that setting as the explanation for the difference. These
are observed results for this account, host, Model, and fixtures, not a
cross-Model or all-input guarantee. Four generation requests reported 1,284
input tokens and 19 output tokens in total. No Tool was proposed or executed.
Credentials were neither displayed nor replaced by the probes.

The [first-party Copilot tokenizer](https://github.com/microsoft/vscode-copilot-chat/blob/main/src/platform/tokenizer/node/tokenizer.ts)
explicitly describes Tool and Tool-call overhead calculations as estimates.
OpenAI separately documents
[`POST /responses/input_tokens`](https://developers.openai.com/api/reference/resources/responses/subresources/input_tokens).
That Responses route was unavailable in the tested Copilot environment; this
does not imply all Copilot counting routes are absent. Anthropic's
[Messages counting documentation](https://platform.claude.com/docs/en/build-with-claude/token-counting)
describes its returned count as an estimate, which may differ from actual usage.

The Claude counting route is usable, but a verified complete-request bound for
V2 remains open. Observed overcounting in these cases does not prove an upper
bound for every permitted request. Do not subtract seven as a correction or
mark a counter `exact` or `upper-bound` on this evidence. Any decision to use
provider-estimated token/cost budgets needs explicit approval. That approval
was subsequently recorded in decision 0010 for V3 only. These earlier probes
did not change Engine source, production Settings, or child-startup refusal.

The temporary reusable probe, its hash, the Engine revision/module hash, and
sanitized machine-readable evidence are retained under
`$env:TEMP/deskpilot-copilot-count-20260906-2121`. The probe passed PowerShell
parsing and PSScriptAnalyzer. This live counting evidence is separate from the
full child-runtime proof and the earlier full Sampler gates.

## Implemented storage boundary

`ProjectBaseline` captures explicitly selected current files without running
Git. It opens selected files before reading, retains Windows file and ancestor
handles, and returns immutable bytes and SHA-256 digests. Tests verify write and
rename denial while those handles are held. Oversized selections, missing files,
case aliases, credential-file names, Git metadata, hard links, junctions,
reparse points, and alternate streams are refused rather than omitted.

Review added refusal of common certificate/key/secret filenames, private-key
content, credential connection strings, and credential-bearing JSON fields.
Malformed or excessively nested JSON is refused when credential inspection
cannot finish. This is a conservative policy, not proof that arbitrary custom
content is secret-free. Operator selection and the approved provider disclosure
boundary remain necessary; do not substitute secret filtering for containment.

`ToolContainer` creates a new container with no host or Project mounts. The
image is read-only, network is `none`, IPC sharing is disabled, and Tool
processes run as an unprivileged identity without capabilities. Only the
protected supervisor retains the narrow container-internal capabilities needed
for ownership, identity changes, and termination. Tools cannot use the Docker
socket or inspect a host process namespace.

All Tool-writable Project, temporary, and home data lives on `/work`, a private
`tmpfs` with explicit byte and inode limits. Seeded input and directories count.
Read-only Project files remain root-owned and non-writable; writable access is
a separate profile. The File implementation uses Linux `openat2` with beneath,
no-link, no-magic-link, and no-cross-mount resolution, then checks file type and
link count. Unsupported Linux architectures or calls fail instead of using a
host File implementation.

### Limits of the component

The approved full-run policy is in decision 0009. The implemented Tool
component enforces only its own portion:

| Bound | Component behavior |
| --- | --- |
| Tool filesystem | 96 MiB and 4,096 inodes by default; at most 192 MiB and 8,192 inodes. |
| Temporary and home writes | Share that filesystem quota; no separate unbounded writable mount. |
| Tool memory and CPU | One half of the configured full-run memory and CPU allocation. |
| Tool process controller | 40 container tasks; this is not the complete Engine-plus-Tool process bound. |
| Command output | Combined stdout/stderr limit per command, default 1 MiB; overflow terminates the component. |
| Duration | The component uses the configured run deadline; full initialization/cancellation race coverage remains open. |
| Proposals | Default 24 MiB and 200 files, additionally bounded by encoded host-storage capacity. |
| Host retention | Reserve the host-storage partition before launch and refuse admission beyond the installation limit. |

The complete-run output, context, Usage, CPU, memory, and process accounting
remain open. File-count enforcement uses filesystem inodes, including directory
and metadata consumption; it is not a poll of directory size. `tmpfs` data also
consumes container memory. This is container containment, not a defense against
a compromised Host Server, Docker daemon, or shared WSL kernel.

## Export and recovery

Export stops unprivileged Tool descendants and revokes later Tool operations
while the supervisor's lease remains active. A trusted File inspection rejects
links, nested mounts, and special files. The host streams a bounded archive
from the trusted image's `tar`, validates paths and types, and computes actual
byte counts and baseline/result digests. It never extracts child archives.

Proposals contain relative paths, operations, bytes, digests, and run/container
provenance. They are retained under the control directory and returned as data.
They are not applied to the real Project, entered into pending changes, or
reported as real-Project `filesWritten`.

Ownership is persisted before launch. An immutable ownership record survives
an interrupted state write. State writes are flushed in place because the
strict Windows ancestor handles deliberately forbid renames; an incomplete
state record blocks admission and requires reconciliation.

Stop cancels command clients, removes the owned container through a separate
control path, and verifies removal. The supervisor exits on control-channel
closure or independent monotonic lease expiry, even while a command is busy.
The owner-death proof kills its temporary owner process, waits for container
exit, and then reconciles the exact recorded orphan.

`Remove-DpChildRun` takes exclusive installation admission, verifies ownership
and Docker labels, removes only matching containers, and records unfinished
work as interrupted. It never reruns it. Retained proposals are removed only
with the explicit `DiscardCompleted` option. There is no global prune. Complete
Host Server restart integration and retention-age enforcement remain open.

## Host Server surfaces

- `GET /api/diagnostics/child` returns read-only policy and missing contracts.
- The existing Diagnostics payload includes `childExecution` with `ready:
  false`.
- `POST /api/conversations/{id}/child-runs` returns `403 child_profile_disabled`
  by default, `503 child_profile_unavailable` when enabled, or `409 busy` during
  an ordinary Turn. It starts nothing and never falls back to Local execution.

These routes retain the existing loopback, origin, and session-token controls.
Readiness invokes no Engine, Docker, network, setup, or cleanup operation.
This is an explicit refusal surface, not completed child-run integration.

## Reproduce the component proof

Requirements: Windows, PowerShell 7.4 or later, the approved local Docker
Desktop Linux/WSL2 backend, the repository checkout, Pester 5, and the canonical
detached launcher from the contributor's PowerShell execution tooling.
Preparation may use the existing pinned Terminal image build and its package
sources. It never selects Isolated mode or changes production Settings.

Run the proof in a detached process, with an explicit Pester 5 manifest:

```powershell
$root = $PWD.Path.Replace("'", "''")
$pester = Get-Module -ListAvailable Pester |
    Where-Object { $_.Version.Major -eq 5 } |
    Sort-Object Version -Descending |
    Select-Object -First 1
if (-not $pester) { throw 'Provide an installed Pester 5 manifest.' }
$log = Join-Path $env:TEMP ('child-proof-' + [guid]::NewGuid() + '.log')
$payload = @"
`$ErrorActionPreference = 'Stop'
try {
    & '$root/tests/live/Invoke-DpChildStorageProof.ps1' -PesterModulePath '$($pester.Path.Replace("'", "''"))' *>&1 | Out-File '$log'
}
catch {
    `$_ | Out-String | Out-File '$log' -Append
    exit 1
}
"@
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($payload))
$launcher = Join-Path $HOME '.copilot/skills/long-running-job-monitor/scripts/Start-DetachedPowerShell.ps1'
& $launcher -EncodedCommand $encoded
$log
```

An explicitly staged Pester 5 manifest can be supplied instead of discovery.
The entry point does not install a module or sign in. Its new temporary evidence
directory contains source hashes, runtime versions, `tests.xml`, and
`summary.json`. `completeChildProfile` remains `false` even when all tests pass.
The suite removes its container resources and its own image tags. A failed or
skipped check is not proof.

## Removal and compatibility

There is no migration for ordinary Turns. Leave child support disabled. For
proof resources, reconcile positively identified runs before discarding data.
Remove only the image tags named in that preparation's runtime record after
verifying no container uses them. Do not remove shared Docker/WSL2, shared image
layers, existing Terminal runtime records, or the real Project.

Full runtime removal, setup/recovery UI, whole-child hostile tests, authenticated
live acceptance, clean-install Engine support, and the complete independent
review gate remain required before releasing the prerequisite.

## See also

- [Approved single-child design](../.memory-bank/decisions/0009-single-child-isolation.md).
- [Parallel Agents dependency plan](../.memory-bank/decisions/0005-parallel-agents.md).
- [Existing Terminal isolation](isolated-terminal.md).
