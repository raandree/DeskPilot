---
schema-version: 1
status: accepted
owner: shared
last-verified: 2026-09-02
source: repository evidence
---

# Active Context

## Current focus

**Every Prompt File in `.github/prompts` has been taken to its own stopping
point on `ai/competitive-landscape-2026`.** The user asked for the work on the
current branch, offline, with no questions. No branch was created or switched,
and nothing was pushed.

Three prompts produced running code — scheduled work, Windows packaging,
localization. Five stopped at a prerequisite gate their own text defines, and
each left a decision record in `.memory-bank/decisions/` rather than a partial
feature. Two were already complete before this session.

## What each Prompt File produced

| Prompt | Outcome |
| --- | --- |
| Per-call approval | Already stopped at its Engine prerequisite (`specs/120`). Unchanged. |
| Diagnostics & support bundle | Already shipped (`85f3f0d`). Unchanged. |
| Scheduled work | **Implemented.** |
| Isolated Tool execution | Gate unmet (no approval, and the Engine cannot route `run_command`). Decision 0001. |
| Microsoft 365 | Contract recorded; blocked on an application registration that cannot exist offline. Decision 0002. |
| Browser automation | Gate unmet on three counts. Decision 0003. |
| Condition-triggered automation | Half the gate now open (scheduled dispatch exists), approval half still closed. Decision 0004. |
| Parallel Agents | Gate unmet; the Engine has no delegation contract. Decision 0005. |
| Windows packaging | **Implemented.** Decision 0006. |
| Localization | **Implemented**, with a stated staged remainder and a ratchet. Decision 0007. |
| Intercom findings (historical) | Not run. The repository records all seven findings as closed, and the Prompt File's own README says not to rerun it on a revision that contains the fixes. |

## Scheduled work

A schedule is a *producer of queued work*, not a second thread. `schedules.json`
holds the schedules, a bounded FIFO queue (20 deep, one entry per schedule) and
the claim of the run in flight. `Update-DpScheduleState` runs on the accept
loop's idle tick with `-AllowTurn` — the one caller with no Turn on the stack —
and from the routes without it, so no route ever starts a Turn inline.

Decisions that carried it: an occurrence later than its catch-up window is
`missed` rather than run late; a second occurrence `coalesces` into the one
already waiting; a persisted claim makes a restart report `interrupted` instead
of repeating work that may already have written files; and `Get-DpScopedSettings`
**ANDs** a scoped Permission with the live one, so an unattended Turn is
structurally incapable of holding more authority than the window. Default `safe`
mode drops Terminal, because per-call approval does not exist and nobody is
present to approve a command.

## Packaging

A portable, self-verifying ZIP rather than an MSI or MSIX. MSIX was rejected
because an unsigned package cannot be installed at all and no signing
credentials exist; MSI was rejected for its elevation posture and build
dependency. The installer verifies the whole SHA-256 inventory **before** it
copies anything, resolves the CurrentUser module path from `PSModulePath` under
`$HOME`, and never touches the data directory. `packwin` is a separate workflow,
so `build` and `test` are unchanged.

## Localization

Build-free ES-module catalogs, English as source and fallback, `Intl` for every
format, the language in `localStorage` like the theme, and server errors
localized by **stable error code** so the wire contract never changes with the
language. The shell chrome, the whole scheduled-work surface and all the safety
copy are complete in both locales. The long tail of strings built inside
`app.js` is not, and a static scan test holds the count at ≤ 105 so it can only
go down.

## Verification

- Focused, red-first: schedules **50/50** (0 passed / 42 failed before the
  implementation existed), packaging **17/17**, localization **13/13**, web
  assets **53/53**.
- Full Sampler `build, test`: **1568/1568**, 16 tasks, 0 errors, 0 warnings.
- `packwin` ran end to end: a 19-file package plus its ZIP and SHA-256. The
  artifact was unpacked **outside** the source tree and re-verified against its
  own manifest — 0 problems, 12 SBOM components, no `.tmp`/`.bak`/`.pfx`.
- AST: 0 parse errors across `source/`, `.build/` and `packaging/`.
  PSScriptAnalyzer: no new findings (`PSUseSingularNouns` on a `*Settings`
  function and the BOM warnings reproduce on `HEAD`).
- `node --check` on `app.js` as an ES module: clean. The German catalog was
  exercised under node against the real `Intl` (plural, number, date, list,
  relative time).

## Not verified

No live loopback smoke of the schedule routes, and no clean-Windows install of
the package — neither was reachable in this session. The packaging decision
records both, with what was checked instead.

## Close-out

Committed on the current branch with the AI co-author trailer; not pushed.
Because this change adds an unattended execution path and a release artifact,
`review: on` is worth requesting for an independent security review.
