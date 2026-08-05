# Active Context

## Current focus

**GitHub sign-in screen fixed (2026-08-05; uncommitted on `main` at the user's
request, not pushed).** A user reported the initial authentication failing. The
engine's per-poll heartbeat lines were appended to the sign-in box, so the
verification link and the user code scrolled out of the 200px scroller within
seconds; with the code auto-copied to the clipboard by the Engine and GitHub
asking for a two-factor code first, the user pasted the device code into the 2FA
field and GitHub rejected it ("Please match the requested format").

Sign-in progress is now a reduced, pinned panel: new `source/web/assets/auth.js`
folds the engine output stream into `{url, code, status}`, `renderAuthProgress`
keeps step 1 (link) and step 2 (code + **Copy code**) in place, and the heartbeat
only rewrites one status line. The code step states that GitHub's password/2FA
prompts are the normal sign-in and that the device code belongs only in the
**Device activation** box. A tokenless end now reports a likely expired code.

## Verification

- TDD red baseline captured (2 failing web-asset tests: missing `auth.js`).
- Full Unit suite after the fix: **400 passed**, 0 failed/skipped/not-run.
- `app.js` and `auth.js` parse as ES modules (`node --check` on `.mjs` copies,
  exit 0); app.js/auth.js/styles.css/WebAssets tests are language-service clean.
- Frontend-only change; the launcher serves `source/web` through
  `DESKPILOT_WEB_ROOT`, so a hard refresh shows it without a rebuild.
- Not browser-smoke-tested against a live device flow.

## Next step

Smoke-test a real sign-in in the browser, then commit only when the user asks.

## Previous focus

Clipboard and native Vision Attachments (2026-07-23; uncommitted on `main`). The
prompt box accepts files from clipboard paste through the same upload and
pending-chip flow as the Attach button and drag-and-drop; uploaded image
Attachments are sent to the Engine through `Invoke-Shp -Image` for Vision-capable
Models. `Resolve-DpAttachmentPath` permits only absolute, existing, registered
`image/*` paths; invalid inputs return `400 invalid_attachment`.

