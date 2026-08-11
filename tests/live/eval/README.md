# DeskPilot parity eval harness

Every prompt in the parity series claims to close a gap between DeskPilot and VS
Code GitHub Copilot Chat. None of them proves it. This turns "DeskPilot feels
weaker" into a number that moves when the code improves — and that catches the
regression when a later change makes it worse again.

**This sends real prompts and spends real credits.** It is deliberately outside
the Pester suite: `build.yaml` runs only `tests/QA` and `tests/Unit`, so nothing
here is reached by `./build.ps1 -Tasks test`. The graders and the comparison
logic *are* unit-tested, against fixture transcripts in
`tests/Unit/fixtures/eval/`, with no live call at all.

## Running it

```powershell
# The whole corpus. -RepositoryRoot is the folder holding the fixture
# repositories the cases name; it is never defaulted, so no machine-specific
# path is committed.
pwsh -File ./tests/live/eval/Invoke-DpParityEval.ps1 -RepositoryRoot V:\Git

# One case, for iterating on a grader.
pwsh -File ./tests/live/eval/Invoke-DpParityEval.ps1 -RepositoryRoot V:\Git -CaseId preflight-banner

# Against a stored baseline. A regression exits non-zero.
pwsh -File ./tests/live/eval/Invoke-DpParityEval.ps1 -RepositoryRoot V:\Git -Baseline output/parity-eval/run-20260811-120000.json

# Diff two stored runs without running anything.
pwsh -File ./tests/live/eval/Invoke-DpParityEval.ps1 -CompareOnly `
    -BaselinePath output/parity-eval/run-a.json -CurrentPath output/parity-eval/run-b.json
```

Results land in `output/parity-eval/run-<id>.json` and `.md`.

Build the module first — `./build.ps1 -Tasks build`. `-Tasks test` does **not**
rebuild, and the harness starts the built Host Server.

## Fixture discipline

Without this the numbers are noise.

- The target repository is **cloned** to a throwaway folder and checked out at
  its pinned SHA before every case, then `git clean -qfdx`. The source
  repository is never checked out, never cleaned and never touched. A harness
  that restores a developer's working tree to make its own numbers reproducible
  has traded one kind of wrong for a worse one.
- The runner asserts the fixture is at the pinned SHA before it starts, and
  fails the case if it is not.
- Model, agent, permissions and iteration cap are fixed per case.
- Each case gets a fresh Host Server process, and therefore a fresh Engine
  Runspace.
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
  case.json     fixture, model, agent, permissions, iteration cap, timeout
  expect.json   the graders
```

`case.json`:

```json
{
  "id": "atelier-pester-gate",
  "set": "regression",
  "note": "the real task this came from",
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

## Graders

Deterministic first, and deterministic only. Never grade prose volume — that is
the metric that made DeskPilot look weak while being irrelevant to whether it
was right.

| Type | Asserts |
|---|---|
| `command_ran` | a regex matched some `tool_call` summary (optionally filtered by `tool`) |
| `tool_used` | a named tool was called at least `min` and at most `max` times |
| `answer_contains` | the final answer matches a regex |
| `files_written` | the changed-path set `equals` or is a `subset` of `paths` |
| `no_files_written` | the working tree is unchanged |
| `git_clean` | nothing was committed |
| `instruction_followed` | a `marker` (literal) or `pattern` (regex) is present in the answer |
| `llm_judge` | **always advisory** — recorded, never gating |

Add `"advisory": true` to any grader to record it without letting it gate. A
case passes when every *gating* grader passes; a case with no gating grader
fails, because a case that asserts nothing has not been measured.

The answer is read from the **Message**, not from the transcript: the prompt-08
transcript deliberately stores a length for model prose, never a copy.

## Efficiency metrics

Recorded per case, never graded: tool calls, iterations, prompt and completion
tokens, cost, credits, wall time, transcript record count. A cheaper run that is
wrong is not better.

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
   - `metrics.wallSeconds`, `metrics.promptTokens`, `metrics.completionTokens`,
     `metrics.costUSD` — from the request details, where the UI exposes them.
   - `changedFiles` — from `git status --porcelain` in the fixture afterwards.
   - `newCommits` — from `git rev-list --count <pinned>..HEAD`.
5. Wrap those entries as `{ "runId": "ghcp-<date>", "deskPilotSha": "n/a-ghcp",
   "cases": [ ... ] }` and diff it with `-CompareOnly`.

Normalising by hand is the point: it forces the same graders onto both sides, so
the comparison is of *correctness*, not of how much each harness printed.

## Closing the loop

The number this entire series exists to produce is the delta between DeskPilot
**before** parity prompt 01 and DeskPilot at current HEAD, over the same corpus:

```powershell
# 1. Baseline: check out the pre-series commit, build, run, keep the result.
git worktree add ../DeskPilot-preseries <pre-01-sha>
# build and run the harness from that worktree, -CasePath pointed at this corpus

# 2. Current HEAD.
pwsh -File ./tests/live/eval/Invoke-DpParityEval.ps1 -RepositoryRoot V:\Git

# 3. The delta.
pwsh -File ./tests/live/eval/Invoke-DpParityEval.ps1 -CompareOnly `
    -BaselinePath <pre-series-run.json> -CurrentPath <head-run.json>
```

If it has not moved, say so. An honest null result is the point of building
this.
