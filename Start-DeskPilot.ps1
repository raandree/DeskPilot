#requires -Version 7.0
<#
.SYNOPSIS
    Launches DeskPilot from a source checkout: builds the module if needed, then starts it.
.DESCRIPTION
    Developer / clone convenience entry point (it is not shipped to the PowerShell
    Gallery). On first run it builds the module with Sampler into
    output/module/DeskPilot/<version>/, imports the newest built manifest, and
    starts the Host Server, serving the web UI from the repo's web/ folder. The
    module function is called module-qualified (DeskPilot\Start-DeskPilot) so it
    always resolves to the module, never back to this script. Gallery-installed
    users call the Start-DeskPilot cmdlet directly instead.
.PARAMETER Port
    TCP port to listen on; 0 (default) picks a free port automatically.
.PARAMETER EngineModulePath
    Optional explicit path to the ShellPilot Engine module.
.PARAMETER DataDir
    Optional override for the per-user data directory where Conversations and the
    lifetime Usage counter are persisted.
.PARAMETER NoBrowser
    Do not open the default browser on start.
.EXAMPLE
    ./Start-DeskPilot.ps1

    Starts DeskPilot and opens the browser at the printed local URL.
#>
[CmdletBinding()]
param(
    [int]$Port = 0,
    [string]$EngineModulePath,
    [string]$DataDir,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot

# DeskPilot is built with Sampler/ModuleBuilder into output/module/DeskPilot/<version>/.
# Build on first run so the launcher works from a fresh clone.
$builtBase = Join-Path $repoRoot 'output/module/DeskPilot'
if (-not (Test-Path -LiteralPath $builtBase)) {
    Write-Host 'Building the DeskPilot module (first run, this may take a moment)...' -ForegroundColor Cyan
    & (Join-Path $repoRoot 'build.ps1') -Tasks build -ResolveDependency | Out-Host
}
$manifest = Get-ChildItem -Path $builtBase -Recurse -Filter 'DeskPilot.psd1' -ErrorAction Stop |
    Sort-Object -Property LastWriteTime -Descending |
    Select-Object -First 1

Import-Module $manifest.FullName -Force

$params = @{
    Port      = $Port
    WebRoot   = (Join-Path $repoRoot 'web')
    NoBrowser = $NoBrowser
}
if ($EngineModulePath) { $params.EngineModulePath = $EngineModulePath }
if ($DataDir) { $params.DataDir = $DataDir }

DeskPilot\Start-DeskPilot @params
