function Test-DpSubagentSupport {
    <#
    .SYNOPSIS
        Probes whether the Engine has the bounded Subagent contract DeskPilot uses.
    .DESCRIPTION
        A capability probe, not a version comparison, in the manner of the MCP
        and approval probes: run_subagent needs Invoke-ShpSubagent with an
        Invoker, a Parent capability, a Capability override and a Budget, an
        Invoke-Shp that can withhold Tools, take a Deadline and an approval
        control, and Get-ShpTool to see which Tools are registered. An Engine
        without them keeps the Subagents Permission inert rather than failing
        every Turn.
    .PARAMETER Runspace
        The Engine Runspace to probe. It must be idle.
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Runspaces.Runspace]$Runspace
    )

    $shell = [powershell]::Create()
    $shell.Runspace = $Runspace
    try {
        $null = $shell.AddScript(@'
# The imported Engine only: a Get-Command by name could autoload some other copy.
$engine = Get-Module -Name ShellPilot | Select-Object -First 1
if (-not $engine) { return $false }
$subagent = $engine.ExportedFunctions['Invoke-ShpSubagent']
$turn = $engine.ExportedFunctions['Invoke-Shp']
$tools = $engine.ExportedFunctions['Get-ShpTool']
if (-not $subagent -or -not $turn -or -not $tools) { return $false }
$need = @{
    subagent = @('DefinitionPath', 'Root', 'Prompt', 'Parent', 'Capability', 'Budget', 'Invoker')
    turn     = @('ExcludeTool', 'DisableTodoList', 'AppendSystemPrompt', 'NonInteractive', 'Deadline', 'ToolCallControl', 'TraceParent')
}
-not (@($need.subagent | Where-Object { -not $subagent.Parameters.ContainsKey($_) }) + @($need.turn | Where-Object { -not $turn.Parameters.ContainsKey($_) })).Count
'@)
        $probe = @($shell.Invoke())
        -not $shell.HadErrors -and $probe.Count -gt 0 -and [bool]$probe[-1]
    }
    catch { $false }
    finally { $shell.Dispose() }
}
