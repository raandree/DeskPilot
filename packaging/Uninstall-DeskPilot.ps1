#Requires -Version 7.0
<#
.SYNOPSIS
    Removes DeskPilot for the current user.
.DESCRIPTION
    Deletes the installed module version and the Start menu shortcut. Your
    Conversations, Settings and Memory live in the DeskPilot data directory and
    are kept unless -RemoveData is passed explicitly - an uninstall must never
    silently destroy a user's work.
.PARAMETER Version
    The version to remove. All installed versions are removed when omitted.
.PARAMETER RemoveData
    Also delete the DeskPilot data directory. This cannot be undone.
.EXAMPLE
    ./Uninstall-DeskPilot.ps1
.EXAMPLE
    ./Uninstall-DeskPilot.ps1 -RemoveData
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$Version,
    [switch]$RemoveData
)

$ErrorActionPreference = 'Stop'

$roots = @($env:PSModulePath -split [System.IO.Path]::PathSeparator |
        Where-Object { $_ -and $_.StartsWith($HOME, [System.StringComparison]::OrdinalIgnoreCase) })

$removed = 0
foreach ($root in $roots) {
    $moduleRoot = Join-Path $root 'DeskPilot'
    if (-not (Test-Path -LiteralPath $moduleRoot -PathType Container)) { continue }

    $versions = if ($Version) {
        @(Get-ChildItem -LiteralPath $moduleRoot -Directory | Where-Object { $_.Name -eq $Version })
    }
    else {
        @(Get-ChildItem -LiteralPath $moduleRoot -Directory)
    }

    foreach ($item in $versions) {
        if ($PSCmdlet.ShouldProcess($item.FullName, 'Remove the installed DeskPilot module')) {
            Remove-Item -LiteralPath $item.FullName -Recurse -Force
            $removed++
        }
    }
    if (-not (Get-ChildItem -LiteralPath $moduleRoot -Force -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $moduleRoot -Force -ErrorAction SilentlyContinue
    }
}

if ($IsWindows) {
    $shortcut = Join-Path $env:APPDATA 'Microsoft' 'Windows' 'Start Menu' 'Programs' 'DeskPilot.lnk'
    if ((Test-Path -LiteralPath $shortcut -PathType Leaf) -and $PSCmdlet.ShouldProcess($shortcut, 'Remove the Start menu shortcut')) {
        Remove-Item -LiteralPath $shortcut -Force
    }
}

Write-Host "Removed $removed installed DeskPilot version(s)." -ForegroundColor Green

$dataDir = if ($IsWindows) { Join-Path $env:LOCALAPPDATA 'DeskPilot' } else { Join-Path $HOME '.deskpilot' }
if ($RemoveData) {
    if ((Test-Path -LiteralPath $dataDir -PathType Container) -and
        $PSCmdlet.ShouldProcess($dataDir, 'Permanently delete your DeskPilot conversations, settings and memory')) {
        Remove-Item -LiteralPath $dataDir -Recurse -Force
        Write-Host "Deleted $dataDir" -ForegroundColor Yellow
    }
}
elseif (Test-Path -LiteralPath $dataDir -PathType Container) {
    Write-Host "Your conversations and settings were kept in $dataDir" -ForegroundColor DarkGray
    Write-Host 'Run this script again with -RemoveData to delete them.' -ForegroundColor DarkGray
}
