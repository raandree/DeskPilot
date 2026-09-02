---
description: "Implement verifiable Windows packaging and installation for DeskPilot"
agent: "software-engineer"
---

# Implement Windows packaging

## Why this feature is useful

DeskPilot targets people who should not need to understand PowerShell modules,
execution policy, or browser launch commands. A verifiable package turns setup,
updates, repair, and removal into predictable product workflows.

## Use case

A lawyer downloads one signed DeskPilot package, verifies the publisher in the
standard Windows dialog, installs without administrator rights, launches from
the Start menu, updates later with consent, and uninstalls without losing their
Conversations unless they explicitly choose to remove data.

## Objective

Deliver a reproducible, CurrentUser Windows package with clean install, launch,
repair/update, and uninstall behavior. Preserve the loopback-only Host Server,
per-launch session token, local data directory, and independently testable
PowerShell module.

## Required context

Read `README.md`, `build.ps1`, `build.yaml`, `RequiredModules.psd1`,
`specs/020-architecture.md`, `specs/050-security-model.md`,
`specs/060-roadmap.md`, and existing launch/update implementation and tests.
Inspect the Sampler build outputs before choosing a packaging technology. Record
the chosen package format, signing path, prerequisites, update relationship, and
rollback strategy in a decision record before implementation.

## Required behavior

- Install for the current user without elevation by default.
- Detect or bundle prerequisites according to the approved design. Never fetch
  mutable dependencies silently during launch.
- Add Start menu and optional desktop shortcuts with the DeskPilot icon.
- Launch exactly one Host Server and open or host the existing SPA without
  widening its bind address or exposing its session token.
- Preserve the existing data directory across update, repair, and ordinary
  uninstall. Offer explicit data removal separately.
- Detect an existing running instance and focus/open it or report a clear state;
  do not start competing Host Servers against the same data.
- Support clean update and rollback when startup validation fails.
- Display installed version, source, and publisher identity in Diagnostics or
  Settings.
- Produce hashes and a software bill of materials for release artifacts.

## Supply-chain and security boundaries

- Make builds reproducible from a clean checkout with pinned tooling and
  dependencies.
- Sign the installer and installed executable/scripts when signing credentials
  are available. Keep credentials outside source, logs, artifacts, and command
  arguments visible to the Model.
- Fail closed on signature or checksum mismatch.
- Use fixed first-party module/package identities. Do not execute content from a
  user-controlled URL.
- Keep install, update, and uninstall non-interactive for automated verification,
  but never bypass user consent in the product flow.
- Document which files and registry entries are created, changed, and removed.

## Test-first proof

Create automated packaging checks before wiring release publication. Cover:

- Clean CurrentUser install on a supported Windows image.
- First launch, loopback bind, session-token enforcement, and one-instance
  behavior.
- Update from the previous supported version with Conversations and Settings
  preserved.
- Failed update rollback.
- Repair and uninstall, both preserving and explicitly removing user data.
- Paths containing spaces and non-ASCII characters.
- Missing prerequisite, corrupt artifact, bad signature, and offline behavior.
- Installed file inventory matches the declared manifest and contains no build
  secrets or temporary files.

## Definition of done

- Add the package target to the existing build without changing normal module
  build semantics.
- Document installation, verification, update, rollback, unattended test flags,
  and uninstall behavior.
- Validate on a clean Windows environment, run the full Sampler build/test gate,
  and inspect the final artifacts from outside the source tree.
- Update `CHANGELOG.md`, roadmap, deployment notes, and routed Memory Bank.
- Commit on a focused topic branch. Do not publish or push.

## Non-goals

- Machine-wide installation by default.
- A hosted DeskPilot service.
- Replacing the PowerShell module as the testable product core.
- Automatic data deletion during uninstall.
- Publishing artifacts or using signing credentials without explicit approval.