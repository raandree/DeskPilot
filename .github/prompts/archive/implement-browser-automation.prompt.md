---
description: "Implement contained Playwright browser automation for one DeskPilot workflow"
agent: "software-engineer"
---

# Implement Playwright browser automation

## Why this feature is useful

Many knowledge-worker tasks end in a web application rather than a file. Browser
automation can carry DeskPilot's reviewed work into those systems, but it also
combines untrusted pages, private local data, and outbound actions. The first
slice must prove one workflow while breaking that attack path by architecture.
DeskPilot's current Browsing Tool can fetch and read a URL; it cannot interact
with a live page, inspect its DOM, click controls, fill fields, or use Playwright.

## Use case

An operations specialist asks DeskPilot to enter an approved maintenance window
into a test service portal. DeskPilot opens an isolated browser profile, stays on
an allow-listed domain, shows each value and action, requires approval before the
final submission, and records screenshots and Activity without exposing unrelated
cookies or local files.

## Objective

Implement browser-only automation for one named, testable workflow and one
allow-listed domain set using Playwright. Do not add general desktop control in
the first slice. Keep the existing Browsing Tool for read-only URL fetches;
Playwright automation is a separate Tool and Permission surface.

## Prerequisite gate

Require shipped per-call approval and isolated execution. Require the user to
name the first workflow, target environment, permitted domains, required private
data, and allowed outbound actions. If any is unspecified, stop and ask for those
decisions before writing code.

## Required context

Read `specs/020-architecture.md`, `specs/030-api-contract.md`,
`specs/040-ui-design.md`, `specs/050-security-model.md`, and the Permission,
Activity, Attachment, Artifact, transcript, and external-content patterns in
`.memory-bank/systemPatterns.md`. Inspect current Browsing Tools and dependencies.
Verify the current `fetch_url` boundary and absence of a Playwright dependency.
Record a decision for the Playwright language binding, Node.js runtime ownership,
browser-binary download and update policy, install size, offline behavior,
process lifecycle, and rollback before implementation. Prefer the official
Playwright package and APIs over direct browser-protocol code.

## Required behavior

- Use a dedicated, isolated browser profile with no personal cookies, extensions,
  password store, history, downloads, or ambient single sign-on by default.
- Pin a supported Playwright version and its compatible browser build. Detect a
  missing or mismatched browser before starting a Turn. Installation and repair
  require explicit user consent; never download executable content silently.
- Constrain top-level navigation, frames, redirects, pop-ups, downloads, uploads,
  and requests to an explicit domain and scheme allow-list.
- Separate page content from trusted instructions. Treat DOM text, accessibility
  trees, screenshots, downloaded files, and browser errors as untrusted Tool data.
- Expose browser actions through a small typed Tool surface. Validate selectors,
  URLs, file paths, text lengths, and action arguments at the Host Server boundary.
- Require per-action approval for submissions, uploads, downloads, permission
  prompts, authentication changes, purchases, messages, deletions, and any action
  with external effect.
- Show the target domain, action, affected values, and irreversible consequence
  before approval without leaking secrets.
- Record navigation and action summaries in Activity with page origin and result.
- Preserve Stop and close the complete browser process tree promptly.
- Bound pages, redirects, downloads, upload bytes, screenshots, execution time,
  output size, and total actions.
- Make headless versus visible operation explicit. Prefer visible operation for
  the first user-facing workflow unless evidence requires headless execution.

## Break the lethal trifecta

Assume every page is prompt-injected. Do not rely on prompt wording or an
injection classifier.

- Remove broad private-data access: provide only task-scoped values through typed
  fields, never the Workspace Folder, clipboard, home directory, or ambient
  credentials.
- Remove arbitrary egress: enforce domain allow-lists below the Model and block
  unknown redirects, URL-bearing image loads, WebSockets, and downloads.
- Remove excessive agency: expose only actions required by the selected workflow
  and gate irreversible actions with high-signal approval.
- Never let page content choose a local file path or add a domain to the allow-list.

If the selected workflow cannot break at least one trifecta leg, record a Blocker
and do not implement it.

## Authentication contract

- Prefer a user-completed interactive sign-in inside the isolated visible browser.
- Never ask the Model to read or type passwords, one-time codes, recovery codes,
  passkeys, or security answers.
- Keep cookies in the dedicated profile only and make retention/clear behavior
  explicit. Do not export them in diagnostics or transcripts.
- Treat CAPTCHA and anti-bot checks as a handoff to the user, never something to
  bypass.

## Test-first proof

Build a local hostile test site before production integration. Cover at least:

- Prompt-injection text cannot access local files, secrets, disallowed domains,
  or an unapproved outbound action.
- Redirects, nested frames, pop-ups, downloads, WebSockets, and resource loads
  cannot bypass the domain policy.
- Page-controlled selectors and values cannot inject script or escape typed Tools.
- Final submission and other external effects block until correlated approval.
- Stale, cross-Turn, and replayed approvals fail.
- Stop kills all browser processes and removes disposable state.
- Authentication secrets never appear in Activity, logs, screenshots, support
  bundles, or Message history.
- Browser/library unavailable, crash, timeout, changed page, and partial action
  states fail visibly without unsafe retry.
- Playwright/package and browser-version mismatch, missing browser binary,
  interrupted installation, offline startup, and repair behavior.

Run a live proof only against a test or staging target with non-sensitive data.

## Definition of done

- Update requirements, architecture, API contract, UI design, security model,
  user guidance, and roadmap for the one approved workflow.
- Add a separate Browser Automation Permission, off by default. Browsing Permission
  must not imply interactive automation authority.
- Add Diagnostics for browser/library version, profile state, and orphan cleanup.
- Document the Playwright and browser-binary installation, verification, update,
  disk use, offline, repair, and uninstall lifecycle.
- Complete an independent agent-security review and resolve every Blocker and
  Major finding before release.
- Run focused tests, the hostile-site suite, the full Sampler gate, and browser
  screenshots at supported viewports.
- Update `CHANGELOG.md` and routed Memory Bank records.
- Commit on a focused topic branch. Do not push.

## Non-goals

- General desktop, keyboard, mouse, or screen control.
- Reusing the user's everyday browser profile.
- Driving an arbitrary locally installed browser outside Playwright's managed
  compatibility contract.
- CAPTCHA bypass or unattended credential entry.
- Arbitrary-domain browsing with private data access.
- A generic record-and-replay system before one workflow is proven.