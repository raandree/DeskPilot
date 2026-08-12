#requires -Version 7.0
# Live smoke test for DeskPilot's MCP wiring. Not part of the Pester suite: it
# starts a real third-party MCP server process. Run it by hand.
#
#   pwsh -File tests/live/Invoke-DpMcpSmokeTest.ps1 -ServerCommand <path-to-azmcp.exe>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ServerCommand,

    [string[]]$ServerArgument = @('server', 'start')
)

$ErrorActionPreference = 'Stop'

$privateRoot = Join-Path $PSScriptRoot '..' '..' 'source' 'Private'
Get-ChildItem -Path $privateRoot -Filter '*.ps1' | ForEach-Object { . $_.FullName }

Write-Host 'Starting the Engine runspace...' -ForegroundColor Cyan
$engine = Initialize-DpEngine
if (-not $engine.Imported) { throw "Engine did not import: $($engine.ImportError)" }
Write-Host "  Engine: $($engine.ModulePath)"
Write-Host "  MCP supported: $($engine.McpSupported)"
if (-not $engine.McpSupported) { throw 'This Engine has no MCP support; update ShellPilot.' }

$script:DeskPilot = @{ Engine = $engine; Mcp = @{ Rows = @{} } }

$settings = Get-DpDefaultSettings
$settings.mcpServers = @(
    ConvertTo-DpMcpServer -InputObject @{
        name    = 'smoke'
        command = $ServerCommand
        args    = $ServerArgument
    }
)

try {
    Write-Host 'Attaching...' -ForegroundColor Cyan
    $results = @(Sync-DpMcpServer -Server @($settings.mcpServers))
    foreach ($r in $results) {
        Write-Host "  row '$($r.name)' ok=$($r.ok) $($r.error)"
        foreach ($s in $r.servers) {
            Write-Host "    $($s.name): state=$($s.state) running=$($s.running) era=$($s.era) protocol=$($s.protocolVersion) tools=$($s.toolCount) pid=$($s.processId) sandboxRequested=$($s.sandboxRequested)"
            Write-Host "    first tools: $((@($s.tools) | Select-Object -First 5) -join ', ')"
        }
    }
    if (-not $results[0].ok) { throw "Attachment failed: $($results[0].error)" }

    Write-Host 'Reconciling again with no change (must not restart it)...' -ForegroundColor Cyan
    $before = $results[0].servers[0].processId
    $again = @(Sync-DpMcpServer -Server @($settings.mcpServers))
    $after = $again[0].servers[0].processId
    Write-Host "  pid before=$before after=$after  (same pid means it was left alone)"
    if ($before -ne $after) { throw 'An unchanged row restarted its server.' }

    Write-Host 'Panel payload:' -ForegroundColor Cyan
    $state = Get-DpMcpState -Settings $settings
    Write-Host "  supported=$($state.supported) rows=$($state.servers.Count) attachedTools=$($state.servers[0].attached[0].toolCount)"

    Write-Host 'Detaching...' -ForegroundColor Cyan
    $null = Sync-DpMcpServer -Server @()
    $survivor = Get-Process -Id $after -ErrorAction SilentlyContinue
    Write-Host "  process $after still running: $([bool]$survivor)"
    if ($survivor) { throw 'The server process outlived its detachment.' }

    Write-Host 'SMOKE TEST PASSED' -ForegroundColor Green
}
finally {
    try { $null = Sync-DpMcpServer -Server @() } catch { $null = $_ }
    $engine.Runspace.Dispose()
}
