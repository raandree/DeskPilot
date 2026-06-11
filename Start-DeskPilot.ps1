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
$manifest = Join-Path $repoRoot 'src/DeskPilot/DeskPilot.psd1'

Import-Module $manifest -Force

$params = @{
    Port      = $Port
    WebRoot   = (Join-Path $repoRoot 'web')
    NoBrowser = $NoBrowser
}
if ($EngineModulePath) { $params.EngineModulePath = $EngineModulePath }
if ($DataDir) { $params.DataDir = $DataDir }

DeskPilot\Start-DeskPilot @params
