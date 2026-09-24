# DeskPilot parity eval harness

Every prompt in the parity series claims to close a gap between DeskPilot and VS
Code GitHub Copilot Chat. None of them proves it. This turns "DeskPilot feels
weaker" into a number that moves when the code improves — and that catches the
regression when a later change makes it worse again.

An agent is not deterministic, so **one trial is an anecdote**. Every case is run
`k` times, each trial in its own throwaway sandbox, and the result is reported
three ways rather than collapsed into one headline. The vocabulary and the
discipline come from [Anthropic — Demystifying evals for AI
agents](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents).

**A live run sends real prompts and spends real credits.** It is deliberately
outside the Pester suite: `build.yaml` runs only `tests/QA` and `tests/Unit`, so
nothing live is reached by `./build.ps1 -Tasks test`, and the runner refuses a
live run outright when a CI environment variable is set. The graders, the
aggregation, the gate and the runner's own orchestration *are* unit-tested,
against fixtures in `tests/Unit/fixtures/eval/`, with no live call at all.

## Running it

### Offline — costs nothing, proves the harness

The offline mode replays committed scripted trials through exactly the same
manifest validation, graders, aggregation and gate. No Host Server, no network,
no Model, no credits. This is the mode CI and the Pester suite use.

```powershell
# The harness self-check: four scripted cases, two trials each.
pwsh -File ./tests/live/eval/Invoke-DpParityEval.ps1 -Offline `
    -ScriptedRunPath ./tests/Unit/fixtures/eval/scripted-run.json -Repeat 2

# The same path with a trial that commits without being asked: exits 1.
pwsh -File ./tests/live/eval/Invoke-DpParityEval.ps1 -Offline `
    -ScriptedRunPath ./tests/Unit/fixtures/eval/scripted-run-unsafe.json -Repeat 2

# The unit tests behind all of it.
./build.ps1 -Tasks test
```

A scripted trial is a hand-written input, not a recording of a Model. **An
offline run says nothing about how DeskPilot or any Model performs**, and the
report labels itself `offline-scripted` so a number from it can never be quoted
as a benchmark.

### Live — opt-in, local, and it spends money

```powershell
# One trial per case: the cheapest possible live run.
pwsh -File ./tests/live/eval/Invoke-DpParityEval.ps1 -RepositoryRoot V:\Git

# Five independent trials per case. This is the one that produces pass@k and
# pass^k worth reading, and it costs five times as much.
pwsh -File ./tests/live/eval/Invoke-DpParityEval.ps1 -RepositoryRoot V:\Git -Repeat 5

# One case, for iterating on a grader.
pwsh -File ./tests/live/eval/Invoke-DpParityEval.ps1 -RepositoryRoot V:\Git -CaseId preflight-banner -Repeat 3

# Against a stored baseline. A regression exits non-zero.
pwsh -File ./tests/live/eval/Invoke-DpParityEval.ps1 -RepositoryRoot V:\Git -Baseline output/parity-eval/run-20260811-120000.json

# Diff two stored runs without running anything.
pwsh -File ./tests/live/eval/Invoke-DpParityEval.ps1 -CompareOnly `
    -BaselinePath output/parity-eval/run-a.json -CurrentPath output/parity-eval/run-b.json
```

`-RepositoryRoot` is the folder holding the fixture repositories the cases name;
it is never defaulted, so no machine-specific path is committed.

Results land in `output/parity-eval/run-<id>.json` and `.md`.

Build the module first — `./build.ps1 -Tasks build`. `-Tasks test` does **not**
rebuild, and a live run starts the built Host Server.

**A live run is refused in CI.** If `CI`, `GITHUB_ACTIONS`, `TF_BUILD`,
`GITLAB_CI` or `JENKINS_URL` is set to anything truthy, the runner stops before
it clones, starts or sends anything. Spending credits stays a deliberate local
act by a person.

## Repetition: what `-Repeat` means

`-Repeat k` runs each case `k` times, bounded to 1–25; 0, a negative number or
1000 is rejected before anything executes. It defaults to **1**, because
repetition is what spends the credits and must be asked for.

Each trial is independent:

- its own sandbox folder under the run root in the system temp directory,
- its own clone of the fixture, checked out at the pinned SHA and `git clean`ed,
- its own `-DataDir`, so its own **Conversation** and its own Project registry,
- its own Host Server process, and therefore its own Engine Runspace.

Nothing carries from trial one to trial two, and no real Project or Conversation
is opened at any point. The run root is a temp folder or the runner refuses to
start, and it is deleted when the run ends.

Every trial of a case shares a **case identity** — a hash of the fixture, commit,
Model, Agent, permissions, iteration cap and prompt. Trials of different
identities cannot be aggregated: the run stops instead of averaging two
configurations into one number. The identity is a hash, so the prompt decides it
without being published.

## The three numbers

| Reported | Means | Use it for |
|---|---|---|
| **first trial** | the single attempt a user would actually have got | what the product does on the first try |
| **pass@k** | at least one of k trials passed | *capability*: can it do this at all? |
| **pass^k** | all k trials passed | *regression* and readiness: does it do it **every** time? |

A case at pass@5 = yes and pass^5 = no *can* do the task but not reliably. Both
are reported, always, per case and per run. The sample count is printed beside
them, because a rate without a denominator is not a measurement.

## What the gate fails on

The runner exits non-zero when any of these is true.

- A **capability** case passed no trial (`pass@k` failed).
- A **regression** case did not pass every trial (`pass^k` failed).
- A **safety invariant** failed in *any* trial, whatever the case's set. One
  unrequested commit in trial three is not excused by two clean trials.
- A case produced **no completed trial**, so it could not be scored.
- A regression case was only **partially sampled**, so `pass^k` cannot be claimed.
- Any **manifest is malformed**, or `-Repeat` is out of bounds. Both are checked
  before anything is cloned, started or sent.

## Honest reporting rules

These are enforced in code and covered by tests, not left to the reader's
goodwill.

- **A missing or incomplete trial can never produce a pass-shaped aggregate.**
  `pass^k` requires k completed trials that passed. Two of three passing and one
  that never ran is reported as `partial`, not as a pass.
- **A grader that could not be measured is neither a pass nor a failure.** If a
  declared artifact was not captured, the grader is *unavailable*, the trial is
  *incomplete*, and the case is named in the report instead of being scored.
- **An unreported cost is unknown, never zero.** Tokens, USD and credits stay
  `null` unless the Engine reported a Usage; the summary prints `unknown`. A
  partially priced run is flagged partial. Zero is a measurement, and a report
  that shows 0.00 USD for a Turn whose Usage never arrived is not a cheap run.
- **A harness error is not evidence about the agent.** An executor that throws
  produces an incomplete trial carrying the error, never a failed one.
- **No benchmark claim without a measured live run.** Nothing in this repository
  claims a pass rate for DeskPilot; the committed numbers are scripted inputs
  that exercise the harness.

## Fixture discipline

Without this the numbers are noise.

- The target repository is **cloned** to a throwaway folder and checked out at
  its pinned SHA before every trial, then `git clean -qfdx`. The source
  repository is never checked out, never cleaned and never touched. A harness
  that restores a developer's working tree to make its own numbers reproducible
  has traded one kind of wrong for a worse one.
- The runner asserts the fixture is at the pinned SHA before it starts, and
  fails the trial if it is not.
- Model, agent, permissions and iteration cap are fixed per case.
- The DeskPilot commit under test is recorded on every run.
- **Caveat recorded on every result:** parity prompt 07 established that the
  Engine Runspace inherits the launcher process's environment (notably
  `PSModulePath`), and that is diagnosed but unfixed. A case whose outcome
  depends on module resolution can therefore differ between machines.

## Case format

One folder per case under `cases/`:

```text
cases/<case-id>/
  prompt.md     the verbatim prompt
  case.json     fixture, model, agent, permissions, iteration cap, timeout, provenance
  expect.json   the graders
```

`case.json`:

```json
{
  "id": "atelier-pester-gate",
  "set": "regression",
  "note": "the real task this came from",
  "provenance": {
    "origin": "adapted",
    "source": "DeskPilot commit 7b79072 (CHANGELOG.md hunk)",
    "verbatimUserPrompt": false
  },
  "repository": "CopilotAtelier",
  "commit": "d283c31",
  "model": "claude-opus-5",
  "agent": "software-engineer",
  "maxToolIterations": 50,
  "permissions": { "browsing": false, "file": true, "terminal": true, "askUser": false, "userTools": true },
  "timeoutSeconds": 900
}
```

`repository` is a **name**, resolved under `-RepositoryRoot`. `set` is
`capability` (can it do this at all?) or `regression` (did a change break
something that worked?).

### Provenance, and what it may not claim

`provenance` is optional on the cases that predate it and required to be honest
when present. `origin` is one of:

| Origin | Means |
|---|---|
| `parity-series` | came from the parity work that founded this corpus |
| `adapted` | derived from a named commit, fixture or document in this repository |
| `synthetic` | authored for the harness; **nobody typed this prompt** |

`source` must name the commit, fixture or document, and
`verbatimUserPrompt` says whether a user actually typed it.

Grow the corpus from **documented** failures — a commit that fixed something, a
regression test, a `docs/` page — and label anything adapted or synthetic as
such. Do not paste private session history into a committed prompt: the corpus
is published the moment it is committed, and a test asserts that no prompt
carries a user path, a credential or `promptHistory` content.

## Graders

Deterministic first, and deterministic only. Never grade prose volume — that is
the metric that made DeskPilot look weak while being irrelevant to whether it
was right. Prefer an **outcome** grader (what the work produced) over a process
grader (how it got there) wherever the outcome is checkable.

| Type | Asserts |
|---|---|
| `command_ran` | a regex matched some `tool_call` summary (optionally filtered by `tool`) |
| `tool_used` | a named tool was called at least `min` and at most `max` times |
| `answer_contains` | the final answer matches a regex |
| `files_written` | the changed-path set `equals` or is a `subset` of `paths` |
| `no_files_written` | the working tree is unchanged |
| `git_clean` | nothing was committed |
| `instruction_followed` | a `marker` (literal) or `pattern` (regex) is present in the answer |
| `file_contains` | a declared workspace file matches a regex, or with `"absent": true` does not |
| `json_field` | a dotted `field` in a declared JSON artifact `equals` a value or `matches` a regex |
| `llm_judge` | **always advisory** — recorded, never gating |

`file_contains` and `json_field` grade the artifact the work produced. The
runner reads **only** the paths those graders declare, **only** from inside the
throwaway fixture, and a path that escapes the workspace is rejected at manifest
validation. A manifest can name a file; it can never name a command. Graders
carrying `script`, `command`, `shell`, `run` or `exec` are rejected outright —
the corpus is data, and data does not execute.

If a declared file was not captured, its grader is reported *unavailable* and
the trial is *incomplete*. Unknown is not the same as wrong.

### How an artifact is actually read

Manifest validation checks *spelling*. It cannot check the filesystem, and the
folder being graded is one the agent under test just had write access to, so a
link in it is expected rather than exotic. Every artifact read therefore goes
through one confined path, and refuses on any of:

- the path resolves outside the trial fixture (the repository's own
  `Resolve-DpWorkspacePath` confinement test — lexical, plus the leaf's link
  target);
- **any** link between the fixture root and the artifact — a junction, a
  symlink or a hardlink, at the leaf or at any ancestor, *even one pointing
  back inside the fixture*. Nothing a grader legitimately reads needs to be
  reached through a link, so the rule is "no links" rather than "the right
  links";
- it is not an existing file;
- it is larger than the byte bound (1 MiB), checked again against the open
  handle;
- it became a link between the check and the read.

A refused artifact is **never truncated, never silently empty, and never a
pass**. It is reported with its reason, its grader is *unavailable*, the trial
is *incomplete*, and — this matters — the Usage that trial spent is still
counted. A trial that paid for an attempt and then could not be measured is
incomplete, not free.

The same rule protects the harness's own state. A run root must *resolve*
under the system temp directory, not merely be spelled that way — and being
under TEMP is not ownership either. A real checkout, a scratch folder or another
tool's state can legitimately live there, so every trial directory is **newly
allocated** and carries a small `.dp-eval-owner` receipt naming the run that
created it. Cleanup refuses anything that cannot show that receipt, refuses a
path that is itself a link, unlinks every link inside before deleting so a
recursive delete can never reach a link's target, and **fails loudly**: an
inspection it cannot complete, a link it cannot unlink, or state still on disk
afterwards stops the deletion and is reported. A trial whose state could not be
removed is incomplete, and a run whose root could not be removed fails the gate —
state that is still there is state the next trial can still read.

Add `"advisory": true` to any grader to record it without letting it gate. A
case passes when every *gating* grader passes; a case with no gating grader is
rejected, because a case that asserts nothing has not been measured.

The answer is read from the **Message**, not from the transcript: the prompt-08
transcript deliberately stores a length for model prose, never a copy.

### Safety invariants

`git_clean` and `no_files_written` are safety invariants by default — both exist
only to catch an action nobody asked for. Any other grader becomes one with
`"safety": true`, which is how a case says "writing anything but this file is a
violation, not a miss".

A safety failure in **any** trial fails the case, whatever its set. An
`llm_judge` can never be a safety invariant, and a grader that is both
`advisory` and `safety` is rejected as malformed: a grader that gates nothing
cannot gate a safety decision.

## Efficiency and Usage

Recorded per case, never graded: duration, tool calls, iterations, prompt and
completion tokens, cost, credits. A cheaper run that is wrong is not better.

Usage is summed only over the trials that reported one. Fields no trial reported
stay `unknown`, and a run where only some trials were priced is flagged
`partial`. The report prints how many trials were priced out of how many ran.

## The GHCP side — manual, and deliberately so

Do **not** try to drive VS Code programmatically. A manual GHCP reference for
even five cases is worth more than an automated one for none.

1. Open the case's fixture repository in VS Code, checked out at the case's
   pinned SHA, in a clean worktree.
2. Select the same model and the same agent the case names.
3. Paste `prompt.md` verbatim into Copilot Chat and let it run to completion.
4. Record, by hand, into a JSON file shaped like one entry of the runner's
   `cases` array:
   - `id` — the case id.
   - `passed` / `failed` — apply the same `expect.json` graders yourself.
   - `metrics.toolCalls` — count the tool invocations shown in the chat.
   - `durationSeconds`, `usage.promptTokens`, `usage.completionTokens`,
     `usage.costUSD` — from the request details, where the UI exposes them.
     Leave out what the UI does not show; do not write a zero for it.
   - `changedFiles` — from `git status --porcelain` in the fixture afterwards.
   - `newCommits` — from `git rev-list --count <pinned>..HEAD`.
5. Wrap those entries as `{ "runId": "ghcp-<date>", "deskPilotSha": "n/a-ghcp",
   "cases": [ ... ] }` and diff it with `-CompareOnly`.

Repeat each case the same `k` times you ran DeskPilot, or say plainly that the
GHCP side is a single trial and the DeskPilot side is not. Comparing best-of-5
against one attempt is not a comparison.

Normalising by hand is the point: it forces the same graders onto both sides, so
the comparison is of *correctness*, not of how much each harness printed.

## Limitations

Say these out loud rather than letting a reader assume otherwise.

- **No live numbers are committed.** Everything in this repository is either a
  scripted harness input or a unit test. There is no measured DeskPilot pass
  rate here, and none should be quoted until someone runs the live mode and
  publishes the run file.
- **`k` is small.** At `-Repeat 5`, a case that passes 4 times has a pass^k of
  `no` and a pass@k of `yes`; neither is a confidence interval. The corpus is
  13 cases, which is enough to expose a pattern and not enough to be a benchmark.
- **The corpus is not 20–50 real failures.** It is the parity-series cases plus
  a small number adapted from documented commits, and one labelled `synthetic`.
  Each case says which it is. Nobody should claim otherwise.
- **The Engine Runspace inherits the launcher environment.** Diagnosed, unfixed,
  and recorded as a caveat on every run; a case that depends on module
  resolution can differ between machines.
- **The advisory `llm_judge` grader is not executed.** It is accepted, recorded
  and never scored, so a case carrying one is measured only by its
  deterministic graders.
- **Artifact confinement is enforced at read time, but link detection depends on
  the platform reporting it.** Junctions and symlinks are refused everywhere a
  reparse point is reported; a hardlink is refused where the platform reports a
  link type for one (it does on Windows). A platform that reports neither would
  let an artifact hardlinked to an already-readable file outside the fixture be
  read. The byte bound and the outside-the-fixture check hold regardless.
- **Offline mode proves plumbing, not performance.** It replays hand-written
  inputs.
- **The GHCP reference side is manual**, so it is as consistent as the person
  doing it.

## Closing the loop

The number this entire series exists to produce is the delta between DeskPilot
**before** parity prompt 01 and DeskPilot at current HEAD, over the same corpus
at the same `k`:

```powershell
# 1. Baseline: check out the pre-series commit, build, run, keep the result.
git worktree add ../DeskPilot-preseries <pre-01-sha>
# build and run the harness from that worktree, -CasePath pointed at this corpus,
# with the same -Repeat as the current run

# 2. Current HEAD.
pwsh -File ./tests/live/eval/Invoke-DpParityEval.ps1 -RepositoryRoot V:\Git -Repeat 5

# 3. The delta.
pwsh -File ./tests/live/eval/Invoke-DpParityEval.ps1 -CompareOnly `
    -BaselinePath <pre-series-run.json> -CurrentPath <head-run.json>
```

If it has not moved, say so. An honest null result is the point of building
this.

## Source

- Anthropic — Demystifying evals for AI agents:
  <https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents>
