# Packaging helpers for the Windows CurrentUser package.
#
# These live in .build/ rather than source/ on purpose: they describe how a
# release artifact is assembled, which is a build concern, and shipping them
# inside the module would make them part of the product's public surface.
# tests/Unit/Packaging.Tests.ps1 dot-sources this same file, so the functions
# the build runs are the functions the tests cover.

function New-DpPackageInventory {
    <#
    .SYNOPSIS
        Lists every file under a root with its size and SHA-256.
    .DESCRIPTION
        The inventory is the package's own claim about what it contains. It is
        written into the artifact and re-verified from it, so a truncated
        download, a quarantined file or an edited payload fails closed instead of
        installing quietly.
    .PARAMETER Path
        The root to inventory.
    .OUTPUTS
        System.Collections.Hashtable[] with path, bytes and sha256.
    #>
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $root = (Resolve-Path -LiteralPath $Path).Path
    $prefix = $root.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) +
        [System.IO.Path]::DirectorySeparatorChar

    @(Get-ChildItem -LiteralPath $root -Recurse -File | Sort-Object FullName | ForEach-Object {
            @{
                # Forward slashes so the manifest reads the same on every platform
                # that might verify it.
                path   = $_.FullName.Substring($prefix.Length).Replace('\', '/')
                bytes  = [long]$_.Length
                sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
            }
        })
}

function Test-DpPackageInventory {
    <#
    .SYNOPSIS
        Verifies a package tree against its own inventory.
    .DESCRIPTION
        Reports every file that is missing, changed, or present but undeclared.
        An empty result means the tree is exactly what the manifest promises.
    .PARAMETER Path
        The package root (the folder holding package-manifest.json).
    .OUTPUTS
        System.String[] - one line per problem, empty when the package verifies.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $root = (Resolve-Path -LiteralPath $Path).Path
    $manifestPath = Join-Path $root 'package-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        return @('package-manifest.json is missing.')
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $problems = [System.Collections.Generic.List[string]]::new()
    $declared = @{}

    foreach ($entry in @($manifest.files)) {
        $declared[[string]$entry.path] = $true
        $full = Join-Path $root ([string]$entry.path)
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            $problems.Add("missing: $($entry.path)")
            continue
        }
        $actual = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash
        if ($actual -ne [string]$entry.sha256) { $problems.Add("changed: $($entry.path)") }
    }

    foreach ($file in @(New-DpPackageInventory -Path $root)) {
        if ($file.path -eq 'package-manifest.json') { continue }
        if (-not $declared.ContainsKey($file.path)) { $problems.Add("undeclared: $($file.path)") }
    }

    @($problems)
}

function New-DpPackageSbom {
    <#
    .SYNOPSIS
        Builds a CycloneDX-shaped software bill of materials for the package.
    .DESCRIPTION
        Names DeskPilot itself and every module the build pinned, so a release
        can be audited without unpacking it. Versions are read from what is
        actually resolved under output/RequiredModules when that is available,
        because a declaration of 'latest' is not a bill of materials.
    .PARAMETER Version
        The DeskPilot version being packaged.
    .PARAMETER RequiredModulesPath
        Path to RequiredModules.psd1.
    .PARAMETER ResolvedModulesPath
        Path to output/RequiredModules, when it exists.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Version,

        [Parameter(Mandatory)]
        [string]$RequiredModulesPath,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$ResolvedModulesPath
    )

    $components = [System.Collections.Generic.List[hashtable]]::new()
    $components.Add(@{
            type    = 'application'
            name    = 'DeskPilot'
            version = $Version
            purl    = "pkg:powershell/DeskPilot@$Version"
        })

    if (Test-Path -LiteralPath $RequiredModulesPath -PathType Leaf) {
        $declared = Import-PowerShellDataFile -LiteralPath $RequiredModulesPath
        foreach ($name in ($declared.Keys | Sort-Object)) {
            $resolved = [string]$declared[$name]
            if ($ResolvedModulesPath -and (Test-Path -LiteralPath (Join-Path $ResolvedModulesPath $name) -PathType Container)) {
                $newest = Get-ChildItem -LiteralPath (Join-Path $ResolvedModulesPath $name) -Directory |
                    Sort-Object Name -Descending | Select-Object -First 1
                if ($newest) { $resolved = $newest.Name }
            }
            $components.Add(@{
                    type    = 'library'
                    name    = [string]$name
                    version = $resolved
                    purl    = "pkg:powershell/$name@$resolved"
                })
        }
    }

    @{
        bomFormat   = 'CycloneDX'
        specVersion = '1.5'
        version     = 1
        metadata    = @{
            timestamp = [datetime]::UtcNow.ToString('o')
            component = @{ type = 'application'; name = 'DeskPilot'; version = $Version }
        }
        components  = @($components)
    }
}

function New-DpWindowsPackage {
    <#
    .SYNOPSIS
        Assembles the CurrentUser Windows package from a built module.
    .DESCRIPTION
        Produces a staging tree containing the built module, the install and
        uninstall scripts, the inventory manifest and the SBOM, then a ZIP beside
        it with its own SHA-256. Nothing is signed here: signing is a separate,
        credential-bearing step and this function must stay runnable from a clean
        checkout with no secrets.
    .PARAMETER ModulePath
        The built module folder (output/module/DeskPilot/<version>).
    .PARAMETER ScriptPath
        The folder holding Install-DeskPilot.ps1 and Uninstall-DeskPilot.ps1.
    .PARAMETER Destination
        Where the package folder and ZIP are created.
    .PARAMETER Version
        The DeskPilot version being packaged.
    .PARAMETER RequiredModulesPath
        Path to RequiredModules.psd1, for the SBOM.
    .PARAMETER ResolvedModulesPath
        Path to output/RequiredModules, for resolved SBOM versions.
    .OUTPUTS
        System.Collections.Hashtable with PackageRoot, ZipPath, ZipSha256, FileCount.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$ModulePath,

        [Parameter(Mandatory)]
        [string]$ScriptPath,

        [Parameter(Mandatory)]
        [string]$Destination,

        [Parameter(Mandatory)]
        [string]$Version,

        [Parameter(Mandatory)]
        [string]$RequiredModulesPath,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$ResolvedModulesPath
    )

    if (-not $PSCmdlet.ShouldProcess($Destination, "Create the DeskPilot $Version Windows package")) { return }

    $packageName = "DeskPilot-$Version"
    $packageRoot = Join-Path $Destination $packageName
    if (Test-Path -LiteralPath $packageRoot) { Remove-Item -LiteralPath $packageRoot -Recurse -Force }
    $null = New-Item -ItemType Directory -Path $packageRoot -Force

    $moduleTarget = Join-Path $packageRoot 'module' 'DeskPilot' $Version
    $null = New-Item -ItemType Directory -Path $moduleTarget -Force
    Copy-Item -Path (Join-Path $ModulePath '*') -Destination $moduleTarget -Recurse -Force

    foreach ($script in 'Install-DeskPilot.ps1', 'Uninstall-DeskPilot.ps1') {
        $source = Join-Path $ScriptPath $script
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Packaging script '$script' was not found at '$ScriptPath'." }
        Copy-Item -LiteralPath $source -Destination (Join-Path $packageRoot $script) -Force
    }

    # A build artifact must never carry temp files or a stray secret into a
    # release, so the staging tree is swept before it is measured.
    $unwanted = @(Get-ChildItem -LiteralPath $packageRoot -Recurse -File |
            Where-Object { $_.Name -like '*.tmp' -or $_.Name -like '*.bak' -or $_.Name -eq '.env' -or $_.Extension -eq '.pfx' })
    foreach ($file in $unwanted) { Remove-Item -LiteralPath $file.FullName -Force }

    $sbom = New-DpPackageSbom -Version $Version -RequiredModulesPath $RequiredModulesPath -ResolvedModulesPath $ResolvedModulesPath
    ($sbom | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $packageRoot 'sbom.json') -Encoding utf8

    $files = @(New-DpPackageInventory -Path $packageRoot)
    $manifest = @{
        product      = 'DeskPilot'
        version      = $Version
        scope        = 'CurrentUser'
        createdUtc   = [datetime]::UtcNow.ToString('o')
        fileCount    = $files.Count
        totalBytes   = ($files | Measure-Object -Property bytes -Sum).Sum
        files        = @($files)
    }
    ($manifest | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $packageRoot 'package-manifest.json') -Encoding utf8

    $zipPath = Join-Path $Destination "$packageName.zip"
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    Compress-Archive -Path (Join-Path $packageRoot '*') -DestinationPath $zipPath -Force

    @{
        PackageRoot = $packageRoot
        ZipPath     = $zipPath
        ZipSha256   = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
        FileCount   = $files.Count
    }
}
