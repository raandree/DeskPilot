function Sync-DpMcpServer {
    <#
    .SYNOPSIS
        Reconciles the Engine's attached MCP servers with DeskPilot's configured
        list.
    .DESCRIPTION
        The Engine deliberately persists nothing and discovers nothing: a server
        exists only because someone called Register-ShpMcpServer in this session,
        and that registration dies with the session. DeskPilot owns the durable
        list, so something has to carry it into the long-lived Engine Runspace at
        startup and whenever the user edits it. This is that something.

        It is a reconciler, not an apply: it compares the configured rows against
        what the Engine actually holds and moves only the difference. That matters
        because attaching is expensive and visible - it starts a third-party
        process, negotiates a protocol era and lists tools - so re-attaching every
        server on every Settings save would restart working processes for no
        reason. An unchanged row is left alone.

        A row that names a configuration file may expand into several servers, so
        ownership is tracked by the names that appeared while the row was applied
        rather than assumed to be one. A live server no row owns is detached: this
        Runspace has exactly one configurer, so anything else is a leftover from a
        row the user has since edited or removed.

        A Faulted server is re-attached rather than skipped. The Engine
        deliberately does not respawn a crashed server by itself - an automatic
        restart inside an unattended loop turns one crash into a crash loop - but
        a user who has just opened the panel and pressed Save is not an unattended
        loop, and leaving a dead server attached would report a tool list the model
        cannot actually call.
    .PARAMETER Server
        The configured server rows, already normalised by ConvertTo-DpMcpServer.
    .PARAMETER Force
        Re-attach every enabled row even when nothing about it changed. This is how
        a frozen tool list is refreshed: the Engine lists a server's tools once, at
        registration, so a server that gained a tool does not offer it until it is
        registered again.
    .OUTPUTS
        System.Collections.Hashtable[]

        One result per configured row: { id, name, ok, error, servers }.
    #>
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Server,

        [switch]$Force
    )

    if (-not $script:DeskPilot.Engine.McpSupported) { return @() }
    if (-not $script:DeskPilot.ContainsKey('Mcp') -or $null -eq $script:DeskPilot.Mcp) {
        $script:DeskPilot.Mcp = @{ Rows = @{} }
    }

    $rows = @($Server | Where-Object { $_ })
    $applied = $script:DeskPilot.Mcp.Rows

    $liveName = {
        @(Invoke-DpEngineCommand -Command 'Get-ShpMcpServer') |
            Where-Object { $_ } |
            ForEach-Object { [string]$_.Name }
    }

    $detach = {
        param($names)
        foreach ($name in @($names | Where-Object { $_ })) {
            try { $null = Invoke-DpEngineCommand -Command 'Unregister-ShpMcpServer' -Parameter @{ Name = $name; Confirm = $false } }
            catch { $null = $_ }
        }
    }

    # A row the user removed or switched off, and any row id that is no longer in
    # the list at all. Detaching first also frees the alias so a renamed row can
    # take it in the same pass.
    $enabledRows = @($rows | Where-Object { $_.enabled })
    $keepIds = @($enabledRows | ForEach-Object { [string]$_.id })
    foreach ($staleId in @($applied.Keys | Where-Object { $keepIds -notcontains $_ })) {
        & $detach $applied[$staleId].names
        $applied.Remove($staleId)
    }

    $results = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($row in $rows) {
        $result = @{ id = [string]$row.id; name = [string]$row.name; ok = $true; error = ''; servers = @() }
        if (-not $row.enabled) {
            $result.ok = $true
            $results.Add($result)
            continue
        }

        $fingerprint = Get-DpMcpFingerprint -Server $row
        $previous = if ($applied.ContainsKey($row.id)) { $applied[$row.id] } else { $null }
        $live = @(Invoke-DpEngineCommand -Command 'Get-ShpMcpServer')
        $owned = @($live | Where-Object { $previous -and $previous.names -contains [string]$_.Name })

        $unchanged = $previous -and
            $previous.fingerprint -eq $fingerprint -and
            $owned.Count -eq @($previous.names).Count -and
            $owned.Count -gt 0 -and
            -not ($owned | Where-Object { $_.State -eq 'Faulted' -or -not $_.Running })

        if ($unchanged -and -not $Force) {
            $result.servers = @($owned | ForEach-Object { ConvertTo-DpMcpServerView -InputObject $_ })
            $results.Add($result)
            continue
        }

        if ($previous) { & $detach $previous.names }

        $before = @(& $liveName)
        try {
            $null = Invoke-DpEngineCommand -Command 'Register-ShpMcpServer' -Parameter (Get-DpMcpRegisterParameter -Server $row)
        }
        catch {
            $result.ok = $false
            $result.error = "$_"
        }

        $after = @(Invoke-DpEngineCommand -Command 'Get-ShpMcpServer')
        $new = @($after | Where-Object { $before -notcontains [string]$_.Name })
        if ($new.Count -gt 0) {
            $applied[$row.id] = @{ fingerprint = $fingerprint; names = @($new | ForEach-Object { [string]$_.Name }) }
            $result.servers = @($new | ForEach-Object { ConvertTo-DpMcpServerView -InputObject $_ })
        }
        else {
            $applied.Remove($row.id)
            if ($result.ok) {
                $result.ok = $false
                $result.error = 'The Engine reported no attached server for this entry.'
            }
        }

        $results.Add($result)
    }

    # Anything still attached that no row owns. One configurer, so a survivor is a
    # leftover - and a leftover still contributes its tools to every Turn.
    $ownedNames = @($applied.Values | ForEach-Object { $_.names } | Where-Object { $_ })
    & $detach @(& $liveName | Where-Object { $ownedNames -notcontains $_ })

    $results.ToArray()
}
