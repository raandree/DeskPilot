---
schema-version: 1
status: accepted
owner: software-engineer
last-verified: 2026-09-29
source: red/green regressions, full local Sampler gate, and Node UI tests
---

# Active context

## Current focus

Switching to a server-only Branch is implemented and validated locally on
`ai/switch-server-only-branch`, created from `main` at `fd9e463`. It is committed
locally, not pushed or merged; both remain user-controlled. Another chat shares
this working tree, so stage exact paths only and never stash, reset or switch
Branches underneath it without asking.

## Latest change

- The Git bar picker and the Branch Wizard offer **Switch** on a server-only
  Branch. `POST /api/git/checkout` accepts `<remote>/<branch>` and delegates to
  `Switch-DpGitBranch`. Local Branches are checked out as before. A remote-only
  Branch gets a pruning fetch of its remote, a `409 branch_gone` refusal when
  the server deleted it, and otherwise one `git checkout --track -b` step, or
  reuse of the local Branch of the same name.
- `Invoke-DpGitFetch` gained `-RemoteName`. Unknown names still answer `400`;
  a refused checkout answers `409` and creates nothing.
- The picker's phantom `origin/…` entries were stale remote-tracking refs: the
  Git bar never fetches. See `debugging-insights.md`.

## Validation

- Red/green: 14 Pester and 3 Node cases failed first for the expected reasons.
- Full `build.ps1 -Tasks build,test`: 2,970 passed, zero failures, 20 skips.
  Eleven Engine-integration cases skip because `DESKPILOT_TEST_ENGINE_PATH` is
  unset here; CI supplies the pinned Engine. 16 tasks, zero errors, seven known
  Memory preservation warnings.
- 64/64 Node UI tests; source and built `app.js` pass the ESM check; analyzer is
  clean on the changed PowerShell. No live browser check was available.

## Previous focus

The agent-reliability package, its review fixes and green hosted CI at
`ee0d2c9` are complete and merged to `main` as `fd9e463`; the details are in
`progress.md`.

## Retained boundaries

Terminal-only approval remains the default. Permissions, isolation and child
opt-in are unchanged; source-bound child proof is invalidated by source changes
and must be renewed before enablement. Parallel topology remains unapproved.
Memory provenance and per-Project scope remain Host-controlled. Keep a private
copy of version-2 Memory before downgrade; never promote confidential notes to
global scope merely to retain them in an older build.
