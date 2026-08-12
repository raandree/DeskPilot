function Get-DpMcpState {
    <#
    .SYNOPSIS
        Builds the MCP panel payload: what is configured, and what the Engine is
        actually running.
    .DESCRIPTION
        Pairs each configured row with the servers it attached, so the panel can
        report the two things that differ often enough to matter: a row the user
        saved that failed to start, and a server that started and has since
        faulted. Reporting only the configuration would make a dead server look
        healthy; reporting only the live list would lose a row that never started
        at all.

        A row that names a configuration file can attach several servers, so the
        pairing follows the ownership the reconciler recorded rather than matching
        on the row's own name.

        An Engine without MCP support reports supported = false and no servers,
        which is what lets the panel explain itself instead of failing.
    .PARAMETER Settings
        The current Settings hashtable.
    .PARAMETER SyncResult
        Optional per-row results from the reconciler, so a registration that just
        failed is reported against the row that caused it. Absent on a plain read.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Settings,

        [AllowNull()]
        [AllowEmptyCollection()]
        [hashtable[]]$SyncResult
    )

    $supported = [bool]$script:DeskPilot.Engine.McpSupported
    $applied = if ($script:DeskPilot.ContainsKey('Mcp') -and $script:DeskPilot.Mcp) { $script:DeskPilot.Mcp.Rows } else { @{} }

    $live = @()
    if ($supported) {
        try { $live = @(Invoke-DpEngineCommand -Command 'Get-ShpMcpServer') } catch { $live = @() }
    }

    $failures = @{}
    foreach ($result in @($SyncResult)) {
        if ($result -and -not $result.ok) { $failures[[string]$result.id] = [string]$result.error }
    }

    $servers = foreach ($row in @($Settings.mcpServers)) {
        $owned = if ($applied.ContainsKey($row.id)) { @($applied[$row.id].names) } else { @() }
        $attached = @($live | Where-Object { $owned -contains [string]$_.Name })

        @{
            id       = [string]$row.id
            name     = [string]$row.name
            source   = [string]$row.source
            command  = [string]$row.command
            args     = @($row.args)
            cwd      = [string]$row.cwd
            envKeys  = @($row.envKeys)
            path     = [string]$row.path
            tools    = @($row.tools)
            enabled  = [bool]$row.enabled
            error    = if ($failures.ContainsKey([string]$row.id)) { $failures[[string]$row.id] } else { '' }
            attached = @($attached | ForEach-Object { ConvertTo-DpMcpServerView -InputObject $_ })
        }
    }

    @{
        supported = $supported
        # The Permission, reported separately from the rows: it withholds every
        # attached server's tools for a Turn without detaching anything, so a panel
        # full of healthy servers can still be contributing nothing.
        enabled   = [bool]$Settings.permissions.mcp
        servers   = @($servers)
    }
}
