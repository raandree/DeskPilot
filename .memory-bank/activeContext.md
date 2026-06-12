# Active Context

## Current focus

**Branch Merge Wizard — SHIPPED (2026-06-12).** The non-expert merge feature from
the grill-me interview (specs/070) is fully implemented end to end: backend
helpers, HTTP routes, and the wizard UI. Next up is the **Clone Wizard**
(specs/080), then a live HTTP smoke of the merge routes.

The Merge Wizard lets a non-expert merge a Branch into the Default Branch (main,
else master) from the explorer Git bar: a merged (check) / not-merged
(exclamation) badge per branch with hover tooltips + a legend, remote-only
branches marked, a "Merge into <default>..." button opening a step wizard
(choose -> preview incoming commits -> merge ff-or-commit -> on conflict an
AI-proposed Merge Plan the user approves before any write, binary keep-ours/theirs
-> result -> local cleanup; remote push+delete behind a SEPARATE confirm; Undo).

## Just completed (this work, 3 commits on ai/merge-wizard)

- **50b4ca5** foundation: specs 070+080, glossary rows, Get-DpDefaultBranch /
  Invoke-DpGitFetch / Get-DpBranchList (+13 tests).
- **c84f628** backend: Get-DpMergePreview, Invoke-DpGitMerge (+autofix
  stash->ff->merge->pop), Invoke-DpGitMergeAbort, Invoke-DpGitMergeUndo,
  Get-DpMergeConflict, New-DpMergePlanPrompt, ConvertFrom-DpMergePlan,
  Invoke-DpMergeApply, Invoke-DpBranchCleanup (+33 tests incl. a real-repo suite).
- **0612594** routes + UI: 8 routes (GET branches, GET merge/preview, POST merge,
  merge/plan [Tools-off Invoke-Shp via Invoke-DpEngineCommand], merge/apply,
  merge/abort, merge/undo, cleanup) in Start-DeskPilot + Invoke-DpRouteHandler;
  specs/030; web/ (git bar badges/legend/remote-only + "Merge into..." entry; the
  Merge Wizard modal in index.html/styles.css/app.js with the conflict sub-flow).

Verified: full Sampler build green TWICE (246 tests, 0 failed, 0 errors, 0
warnings); app.js parses as an ES module (.mjs check); HTML/CSS/JS + all .ps1
clean; route-table names match handler cases 1:1 (8/8). CHANGELOG [Unreleased]
"Added" entry written.

## Next steps

1. **Live HTTP smoke of the merge routes** (recommended before merge to main):
   start Start-DeskPilot with a real-repo Project, exercise /api/git/branches,
   /merge/preview, a real merge, a conflict -> /merge/plan -> /merge/apply, and
   /cleanup (local-only). The plan route needs the Engine authenticated. Helpers
   are already real-repo-tested; this validates the HTTP + UI wiring.
2. **Manual browser smoke** of the wizard (badges render, tooltips, each step).
3. **Clone Wizard (spec 080):** one New Project Wizard (clone-vs-local first
   screen); Invoke-DpGitClone (validate URL, derive repo basename, clone via
   Invoke-DpGitCommand, never-throw); POST /api/projects/clone; reuse the folder
   picker; SSH + ambient credentials only; auto-select the new Project.
4. Then resume the parked publish/Sampler work (Phase B/D) if desired.

## Design decisions in force (Merge Wizard, signed off 2026-06-12)

- Merge target / "merged?" basis = the Default Branch (origin/HEAD, else main, else master).
- Conflicts: AI PROPOSES a Merge Plan (pure-reasoning Turn, Tools off); user approves; DeskPilot writes+commits. Binary = keep-ours/theirs.
- Strategy ff-else-merge-commit; autofix stash->ff->merge->pop; abort safely on a pull conflict.
- Cleanup auto local delete; remote push+delete behind a SEPARATE explicit confirm; ambient git credentials only.
- Badge fetches from origin first in the wizard (accuracy); the Git bar uses no-fetch (speed). Remote-failure keeps the local merge. Undo resets the default to the pre-merge sha (local only).

## Constraints in force

- Localhost-only bind + per-launch session token; single active Turn at a time
  (the merge/plan route guards on $state.TurnRunning, returns 409 if busy).
- Filesystem + Git endpoints confined to the selected Project's folder; git runs
  via Invoke-DpGitCommand (process, no shell). Remote push/delete is the only
  networked privileged action and requires a separate explicit per-action confirm.
- Canonical glossary terms only. README assets in assets/; in-app under web/assets/.

## Previous focus (publish/Sampler -- partially shipped)

Phase A (Sampler-ize) + Phase C (CI mirroring ShellPilot, deploy gated OFF) DONE.
Pending: Phase B (module-relative -WebRoot default, CopyPaths [web], manifest
metadata, MIT LICENSE, built-module smoke) and Phase D (go-live: pin stable
ShellPilot, iwr|iex bootstrap, add GalleryApiToken/GitHubToken secrets).
