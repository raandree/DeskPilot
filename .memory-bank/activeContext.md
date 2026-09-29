---
schema-version: 1
status: accepted
owner: software-engineer
last-verified: 2026-09-29
source: red/green UI regressions, web-asset contracts, and desktop/mobile browser evidence
---

# Active context

## Current focus

The requested thinking and file Activity layout is implemented and validated on
the existing `ai/switch-server-only-branch`. Another chat shares this working
tree: preserve its server-only Branch work at `8634db8`, stage only owned paths,
and do not stash, reset, or switch Branches. No push or Merge was requested.

## Latest change

- Thinking now starts a new section at each Engine iteration divider, including
  Tool-only outputs. Tokens stay in their current section; intermediate answer
  text and the final answer keep their chronological positions.
- Tasks, Changes, and Activity precede the output flow. Activity and file lists
  start collapsed, preserve manual expansion during updates, and remain
  keyboard-accessible. Keep, Undo, Diff viewer, and approvals remain available.
- Remove the mirrored, truncated thinking line above the composer. Generic
  Working feedback remains before reasoning arrives or when thinking is off.
- Completed live sections survive finalization. Stored traces retain explicit
  iteration boundaries; prose-only records cannot recover missing boundaries.
  No Host Server, Permission, Engine, or persisted schema change was needed.

## Validation

- Twelve focused Node cases pass; ten failed against the old behavior and two
  characterize retained behavior. All 76 native Node UI tests pass, including
  the other chat's Branch regressions. JavaScript syntax check passes.
- All 54 web-asset Pester contracts pass in an isolated process, zero skips.
- Six headless Edge journeys at 1440px and 390px pass: Send/completion,
  regenerate/Stop, and edit without reasoning. Verify actual section bounds,
  latest-line visibility, keyboard disclosure controls, manual-scroll retention,
  and approval denial. No page errors, unexpected requests, or Model calls.
  These are loopback SSE fixtures using the real UI, not live Engine acceptance.

## Concurrent work retained

`8634db8` adds server-only Branch switching with a pruning fetch, refusal of
deleted Branches, and local tracking-Branch reuse. Its earlier full Sampler gate
passed 2,970 tests with 20 environment skips; see `progress.md` for that separate
change's evidence. The agent-reliability work is already merged at `fd9e463`.

## Retained boundaries

Terminal-only approval remains the default. Permissions, isolation and child
opt-in are unchanged; source-bound child proof is invalidated by source changes
and must be renewed before enablement. Parallel topology remains unapproved.
Memory provenance and per-Project scope remain Host-controlled. Keep a private
copy of version-2 Memory before downgrade; never promote confidential notes to
global scope merely to retain them in an older build.
