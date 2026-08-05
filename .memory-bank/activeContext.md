---
schema-version: 1
status: accepted
owner: shared
last-verified: 2026-08-05
source: repository evidence
---

# Active Context

## Current focus

**Ask-User now renders a bundled Questionnaire wizard (2026-08-05; uncommitted
on `main`, not pushed).** ShellPilot's built-in `ask_user` describes one free-text
clarification, so system-prompt guidance alone still produced one question per
call. DeskPilot now registers a trusted, permission-gated `ask_questions` User
Tool whose JSON-string contract bundles up to ten related questions.

The Host Server bounds and normalizes untrusted Questionnaire JSON. The SPA
renders numbered single-select choices, checkmarked multi-select choices,
conditional or free-text-only input, previous/next navigation, progress,
collapse, close-to-Stop, submit, and an answer summary. Plain `ask_user` remains
a one-step free-text fallback. Structured answers resume the same Turn as one
correlated JSON string.

## Verification

- TDD covered normalization/fallback, protocol injection, Tool registration and
  permission removal/restore, bridge return, Activity mapping, state and answer
  serialization, duplicate options, keyboard navigation, and post-Stop reprompt.
- Full Sampler build and test passed **441/441**, exit 0.
- Original German request live test bundled **10 questions**, including three
  multi-select steps and option/free-text combinations, then completed after a
  correlated JSON answer.
- Browser test verified radio, checkbox/checkmark, and free-text-only steps;
  mobile width **342 / 390 px**; three-row answer summary; final reply `Danke!`;
  Activity showed the Questionnaire title rather than JSON.
- Independent agent-security review approved with no Blocker or Major finding;
  cancellation and keyboard residuals were then hardened with regression tests.

## Next step

Try the Questionnaire on the running final server. Keep the changes uncommitted
until explicitly requested; do not push without an explicit request.

## Previous focus

The Project chip derives its visible leaf from the selected Workspace Folder,
sizes to short names, and ellipsizes longer leaves with a full-name tooltip.
