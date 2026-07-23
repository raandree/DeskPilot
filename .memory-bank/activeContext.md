# Active Context

## Current focus

**Clipboard and native Vision Attachments implemented (2026-07-23; uncommitted
on `main`, not pushed).** The prompt box now accepts files from clipboard paste
through the same upload and pending-chip flow as the Attach button and
drag-and-drop. Text-only paste remains normal text input. Uploaded image
Attachments from all three entry points are sent to the Engine through
`Invoke-Shp -Image` for Vision-capable Models; non-image Attachments retain the
existing File Tool path note.

The Message request accepts optional `images` paths. The Host Server records each
successfully written upload in a per-launch, OS-case-aware Attachment registry
(`normalized path -> MIME type`). `Resolve-DpAttachmentPath` permits only
absolute, existing, registered `image/*` paths, preventing a crafted Message from
nominating arbitrary local files while allowing a pending Attachment to survive
a Project switch. Invalid inputs return `400 invalid_attachment`.

## Verification

- TDD red baselines captured for clipboard extraction/wiring, Engine `Image`
  forwarding, path validation, route forwarding, upload registration, MIME
  enforcement, and Project switching.
- Focused helper + route suite: **391 passed**, 0 failed/skipped/not-run.
- Browser asset tests: **5 passed**; `app.js` and `attachments.js` parse as ES
  modules.
- Final full Sampler build: **409 passed**, 0 failed/skipped/not-run; **17 tasks,
  0 errors, 0 warnings**.
- Final route rerun after formatting: **4 passed**; changed route and registry
  files are PSScriptAnalyzer-clean.
- Live HTTP smoke on port 4280: `/api/health` returned `status=ok` with the Engine
  imported, and `/assets/attachments.js` returned 200 with the paste handler.
- Two focused security reviews: no Blocker or Major findings after the registry
  hardening. Residual risk is limited to user-declared upload MIME types in this
  local, token-gated flow.
- The Host Server remains running on port 4280 for a manual browser interaction
  smoke; no automated browser interaction was available.

## Next step

Review or manually smoke-test paste behavior, then commit only when the user asks.
