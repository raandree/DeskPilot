---
schema-version: 1
status: accepted
owner: software-engineer
last-verified: 2026-09-02
source: repository evidence
---

# 0006 — Windows packaging: a verifiable CurrentUser package, not an MSI

## Decision

Ship a **portable, self-verifying ZIP** containing the built module, an install
and an uninstall script, a hashed file inventory, and a CycloneDX SBOM. Build it
with a separate `packwin` workflow (`build` → `pack_windows`) so the normal
`build` and `test` semantics are untouched.

## Formats considered

| Format | Elevation | Reproducible from a clean checkout | Tooling | Verdict |
| --- | --- | --- | --- | --- |
| **MSI (WiX)** | Per-user MSI is possible but fragile; most guidance assumes machine-wide | Needs the WiX toolset pinned | Heavy | Rejected: elevation risk and a large build dependency for a product whose payload is a PowerShell module |
| **MSIX** | Clean per-user model | **Requires a signing certificate to install at all** | `makeappx`/`signtool`, Windows SDK | Rejected for now: unsigned MSIX cannot be installed, so it would make the package unusable until signing credentials exist |
| **Squirrel / NSIS / Inno** | Per-user possible | Another third-party toolchain | Medium | Rejected: same dependency cost, no benefit over a ZIP for a module payload |
| **PowerShell Gallery only** | None | Already in place | None | Kept, but insufficient: the prompt's user should not have to know what `Install-Module` is |
| **Portable ZIP + install script** | **None** | Yes — `Compress-Archive` and `Get-FileHash` only | None | **Chosen** |

The deciding argument is that DeskPilot's payload *is* a PowerShell module. An
installer format's main value is registering machine state, and this product
deliberately registers none: it copies a module into the user's own module path
and adds one shortcut. Anything heavier buys ceremony, a build dependency, and
an elevation prompt this product does not need.

## Properties the package guarantees

- **CurrentUser, no elevation.** The install target is resolved from
  `PSModulePath`, filtered to entries under `$HOME`, so a redirected Documents
  folder still lands correctly. The scripts contain no `RunAs`, no
  `ProgramFiles`, and no `HKLM` — asserted by a test, not by intention.
- **Fails closed.** `package-manifest.json` lists every file with its SHA-256.
  The installer verifies the whole inventory **before** copying anything, so a
  truncated download or an edited payload is rejected while nothing is on disk.
  `Test-DpPackageInventory` reports missing, changed, and undeclared files.
- **User data survives.** Install and update never touch the data directory.
  Uninstall keeps it and says so; deleting it requires an explicit `-RemoveData`
  on a `ConfirmImpact = 'High'` script.
- **Auditable.** `sbom.json` names DeskPilot and every pinned dependency,
  preferring the version actually resolved under `output/RequiredModules` over a
  `latest` declaration.
- **No build leftovers.** The staging tree is swept of `*.tmp`, `*.bak`, `.env`
  and `*.pfx` before it is measured, so a signing key or scratch file cannot
  ride into a release.

## Not done, and why

- **Signing.** No credentials are available, and the prompt is explicit that they
  must not be used without approval. The design keeps signing a separate,
  additive step: sign the ZIP and the installed scripts, then publish the
  detached hash alongside. Nothing in the current package prevents it.
- **Clean-machine validation.** Requires a fresh Windows image, which is not
  available here. What *was* verified: the artifact was unpacked outside the
  source tree and re-verified against its own manifest (0 problems, 20 files),
  the SBOM lists 12 components, and no `.tmp`/`.bak`/`.pfx` file is present.
- **Update/rollback and one-instance behaviour.** DeskPilot already owns its own
  update path (`Invoke-DpSelfUpdate` plus `Restart-DpHost`, spec 010 FR-UP1/UP2),
  and the package deliberately does not compete with it: the package installs a
  version, the running product updates itself. Wiring the package into the update
  channel is a follow-up that needs the signing decision first.

## Release procedure

```powershell
./build.ps1 -Tasks packwin
# → output/package/DeskPilot-<version>.zip
#   output/package/DeskPilot-<version>.zip.sha256
#   output/package/DeskPilot-<version>/package-manifest.json, sbom.json
```

Verify from outside the tree before publishing:

```powershell
Expand-Archive DeskPilot-<version>.zip -DestinationPath $tmp
. ./.build/DeskPilotPackaging.ps1
Test-DpPackageInventory -Path $tmp   # must be empty
```
