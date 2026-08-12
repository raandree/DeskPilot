function Get-DpMcpContext {
    <#
    .SYNOPSIS
        States DeskPilot's own MCP position for the system prompt.
    .DESCRIPTION
        Asked "which MCP servers are available?", a model with nothing attached
        has no authoritative answer and goes looking: it finds another
        application's configuration file - VS Code's `mcp.json` is the usual one -
        and reports it as though it described DeskPilot. That answer is confidently
        wrong, and on a machine with no VS Code it simply becomes a different wrong
        answer.

        The fix is to say so. One short line, because the model cannot ration or
        report what it cannot see, and because DeskPilot's MCP configuration is its
        own: nothing is inherited from any editor, and a configuration file
        belonging to another program describes that program's servers, not these.

        With servers attached the line is still worth its tokens: the Engine offers
        the tools but nothing tells the model they are grouped into servers, which
        prefix belongs to which, or that the list is frozen at attachment.
    .PARAMETER Server
        The attached servers, already mapped by ConvertTo-DpMcpServerView. Empty
        when nothing is attached.
    .PARAMETER Supported
        Whether the resolved Engine understands MCP at all. Without it there is no
        position to state and the block is omitted entirely.
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [hashtable[]]$Server,

        [switch]$Supported
    )

    if (-not $Supported) { return '' }

    $attached = @($Server | Where-Object { $_ -and $_.name })
    if ($attached.Count -eq 0) {
        return 'No MCP servers are attached to DeskPilot, so you have no MCP tools. DeskPilot keeps its own MCP configuration (Settings > MCP servers) and inherits none from any editor - an mcp.json belonging to VS Code or another program describes that program''s servers, not yours. If you are asked which MCP servers are available, say that none are attached rather than reporting another application''s configuration file as if it were DeskPilot''s.'
    }

    $lines = foreach ($item in $attached) {
        $state = if ($item.running -and $item.state -ne 'Faulted') { '' } else { ' (stopped - its tools will fail)' }
        '- {0}: {1} tool(s), named mcp_{0}_*{2}' -f $item.name, [int]$item.toolCount, $state
    }

    @(
        'MCP servers attached to DeskPilot, whose tools are already in your tool list:'
        $lines
        'This is the whole set. Each server''s tool list was fixed when it was attached, so it will not change during this task, and a configuration file belonging to another program does not describe these servers.'
    ) -join "`n"
}
