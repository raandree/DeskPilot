#Requires -Version 7.0
<#
.SYNOPSIS
    Installs DeskPilot for the current user, without elevation.
.DESCRIPTION
    Copies the packaged module into the CurrentUser module path and adds a Start
    menu shortcut. It never writes outside the user's own profile, never asks for
    administrator rights, and never touches the DeskPilot data directory - an
    update or a repair therefore cannot lose Conversations or Settings.

    The package inventory is verified before anything is copied, so a truncated
    download or an edited payload fails closed.
.PARAMETER PackageRoot
    The unpacked package folder. Defaults to the folder holding this script.
.PARAMETER NoShortcut
    Skip the Start menu shortcut.
.PARAMETER SkipVerify
    Skip inventory verification. Intended only for a build-time smoke test.
.EXAMPLE
    ./Install-DeskPilot.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$PackageRoot = $PSScriptRoot,
    [switch]$NoShortcut,
    [switch]$SkipVerify
)

$ErrorActionPreference = 'Stop'

$manifestPath = Join-Path $PackageRoot 'package-manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "This does not look like a DeskPilot package: package-manifest.json is missing from '$PackageRoot'."
}
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

if (-not $SkipVerify) {
    Write-Host 'Verifying the package...' -ForegroundColor Cyan
    foreach ($entry in @($manifest.files)) {
        $full = Join-Path $PackageRoot ([string]$entry.path)
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            throw "The package is incomplete: '$($entry.path)' is missing. Download it again."
        }
        if ((Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash -ne [string]$entry.sha256) {
            throw "The package is damaged: '$($entry.path)' does not match its checksum. Download it again."
        }
    }
}

$version = [string]$manifest.version
$source = Join-Path $PackageRoot 'module' 'DeskPilot' $version
if (-not (Test-Path -LiteralPath $source -PathType Container)) {
    throw "The packaged module was not found at '$source'."
}

# CurrentUser scope, from PSModulePath rather than a guess, so a redirected
# Documents folder (OneDrive, a roaming profile) still installs to the right
# place. Machine-wide locations are excluded outright: this installer must never
# need elevation.
$userModuleRoot = @($env:PSModulePath -split [System.IO.Path]::PathSeparator |
        Where-Object { $_ -and $_.StartsWith($HOME, [System.StringComparison]::OrdinalIgnoreCase) } |
        Select-Object -First 1)
if (-not $userModuleRoot) {
    $userModuleRoot = @(Join-Path $HOME 'Documents' 'PowerShell' 'Modules')
}
$target = Join-Path $userModuleRoot[0] 'DeskPilot' $version

if ($PSCmdlet.ShouldProcess($target, 'Install the DeskPilot module for the current user')) {
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
    $null = New-Item -ItemType Directory -Path $target -Force
    Copy-Item -Path (Join-Path $source '*') -Destination $target -Recurse -Force
    Write-Host "Installed DeskPilot $version to $target" -ForegroundColor Green
}

if (-not $NoShortcut -and $IsWindows) {
    $startMenu = Join-Path $env:APPDATA 'Microsoft' 'Windows' 'Start Menu' 'Programs'
    $shortcut = Join-Path $startMenu 'DeskPilot.lnk'
    if ($PSCmdlet.ShouldProcess($shortcut, 'Create a Start menu shortcut')) {
        try {
            $shell = New-Object -ComObject WScript.Shell
            $link = $shell.CreateShortcut($shortcut)
            $link.TargetPath = (Get-Process -Id $PID).Path
            $link.Arguments = '-NoLogo -NoExit -Command "Import-Module DeskPilot; Start-DeskPilot"'
            $link.WorkingDirectory = $HOME
            $link.Description = 'DeskPilot'
            $icon = Join-Path $target 'web' 'assets' 'logo-mark.png'
            if (Test-Path -LiteralPath $icon -PathType Leaf) { $link.IconLocation = $link.TargetPath }
            $link.Save()
            Write-Host "Start menu shortcut created: $shortcut" -ForegroundColor Green
        }
        catch {
            Write-Warning "The Start menu shortcut could not be created: $_"
        }
    }
}

Write-Host ''
Write-Host 'Start DeskPilot from the Start menu, or run:' -ForegroundColor Cyan
Write-Host '  Import-Module DeskPilot; Start-DeskPilot' -ForegroundColor White
Write-Host ''
Write-Host 'Your conversations and settings live in %LOCALAPPDATA%\DeskPilot and were not touched.' -ForegroundColor DarkGray
