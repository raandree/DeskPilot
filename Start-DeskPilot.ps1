#requires -Version 7.0
<#
.SYNOPSIS
    Launches DeskPilot: imports the Host Server module and starts it.
.DESCRIPTION
    Thin entry point. Imports the DeskPilot module from src/ and starts the Host
    Server, serving the web UI from web/. The module function is called with its
    module-qualified name so it always resolves to the module (never back to this
    script).
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
