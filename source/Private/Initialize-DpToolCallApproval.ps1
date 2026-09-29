function Initialize-DpToolCallApproval {
    <#
    .SYNOPSIS
        Binds supported Host approval controls in the Engine's own Runspace.
    .DESCRIPTION
        Returns the Invoke-Shp parameter binding for the current ToolCallControl
        interface or the legacy ToolCallApprover. Controls are Host capabilities,
        never registered User Tools. MCP identities are captured from actual
        registrations rather than guessed from lossy namespaced names.
    .PARAMETER Runspace
        The idle Engine Runspace.
    .PARAMETER Context
        The Host-owned context prepared for this Turn.
    .PARAMETER Bridge
        The existing approval rendezvous.
    .PARAMETER TimeoutSeconds
        Maximum operator wait for one action.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][System.Management.Automation.Runspaces.Runspace]$Runspace,
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][AllowNull()][object]$Bridge,
        [ValidateRange(1, 86400)][int]$TimeoutSeconds = 900
    )
    $contract = Get-DpToolCallApprovalContract -Runspace $Runspace
    if (-not $contract) {
        throw 'This Engine provides neither ToolCallControl nor ToolCallApprover. Broader approval was refused before any Tool or Model invocation.'
    }
    if ($null -eq $Bridge) { throw 'The Host approval bridge is unavailable; no Tool was approved.' }
    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.AppendLine('param($Context, $Bridge, [int]$TimeoutSeconds, [string]$Contract)')
    foreach ($name in @('Get-DpPropertyValue', 'ConvertTo-DpTerminalExecution', 'New-DpApprovalRequest', 'Invoke-DpToolCallApproval', 'Invoke-DpToolCallControl')) {
        $command = Get-Command -Name $name -CommandType Function -ErrorAction Stop
        [void]$builder.AppendLine("function global:$name {")
        [void]$builder.AppendLine($command.Definition)
        [void]$builder.AppendLine('}')
    }
    [void]$builder.AppendLine(@'
$global:DeskPilotToolApprovalContext = $Context
$global:DeskPilotToolApprovalBridge = $Bridge
$global:DeskPilotToolApprovalTimeout = $TimeoutSeconds
if ($Contract -ceq 'ToolCallControl') {
    $global:DeskPilotMcpApprovalIdentity = @{}
    $engine = Get-Module -Name ShellPilot | Select-Object -First 1
    if ($engine) {
        $catalog = & $engine { ,$script:ShpMcpServers }
        if ($catalog -isnot [System.Collections.IDictionary]) {
            throw 'The Engine MCP registration catalog is unavailable or incompatible; dispatch was refused.'
        }
        $identities = @(
            foreach ($server in $catalog.Values) {
                if ($server.State -cne 'Ready') { continue }
                foreach ($tool in $server.Tools) {
                    @{ Name = $tool.Name; Server = $server.Name; Tool = $tool.OriginalName }
                }
            }
        )
        if ($identities.Count -gt 4096) { throw 'The MCP approval identity catalog exceeds its bound.' }
        foreach ($entry in $identities) {
            if ($entry.Name -isnot [string] -or $entry.Name -cnotmatch '\A[A-Za-z0-9_-]{1,128}\z' -or
                $entry.Server -isnot [string] -or [string]::IsNullOrWhiteSpace($entry.Server) -or
                $entry.Tool -isnot [string] -or [string]::IsNullOrWhiteSpace($entry.Tool) -or
                $global:DeskPilotMcpApprovalIdentity.ContainsKey($entry.Name)) {
                throw 'An MCP approval identity is invalid or ambiguous.'
            }
            $global:DeskPilotMcpApprovalIdentity[$entry.Name] = @{ Server = $entry.Server; Tool = $entry.Tool }
        }
    }
    $global:DeskPilotToolApprovalParameters = @{ ToolCallControl = @{
        SchemaVersion = 1; FailPosture = 'Closed'; PolicyId = [string]$Context.turnId
        PreToolCall = {
            param($Request)
            Invoke-DpToolCallControl -Request $Request -Context $global:DeskPilotToolApprovalContext -Bridge $global:DeskPilotToolApprovalBridge -McpToolMap $global:DeskPilotMcpApprovalIdentity -TimeoutSeconds $global:DeskPilotToolApprovalTimeout
        }
    } }
} else {
    $global:DeskPilotToolApprovalParameters = @{ ToolCallApprover = {
        param($Call)
        Invoke-DpToolCallApproval -Call $Call -Context $global:DeskPilotToolApprovalContext -Bridge $global:DeskPilotToolApprovalBridge -TimeoutSeconds $global:DeskPilotToolApprovalTimeout
    } }
}
'@)
    $setup = [powershell]::Create()
    $setup.Runspace = $Runspace
    try {
        $null = $setup.AddScript($builder.ToString()).AddArgument($Context).AddArgument($Bridge).AddArgument($TimeoutSeconds).AddArgument($contract)
        $setup.Invoke() | Out-Null
        if ($setup.HadErrors) { throw 'The Engine approval bridge could not be initialized. Verify Engine control and MCP registration catalog compatibility; dispatch was refused.' }
        $binding = $Runspace.SessionStateProxy.GetVariable('DeskPilotToolApprovalParameters')
        if ($binding -isnot [hashtable] -or $binding.Count -ne 1 -or -not $binding.ContainsKey($contract)) {
            throw 'The Engine approval parameter binding was not created; dispatch was refused.'
        }
        $binding
    }
    finally { $setup.Dispose() }
}
