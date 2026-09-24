function Initialize-DpToolCallApproval {
    <#
    .SYNOPSIS
        Creates the Host approval callback in the Engine's own Runspace.
    .DESCRIPTION
        Refuses Engines without specification 120's declared ScriptBlock
        parameter. The callback is a Host capability, never a registered User
        Tool. Its context is prepared before dispatch and its bridge is revoked
        on Stop, scope changes and the Turn boundary.
    .PARAMETER Runspace
        The idle Engine Runspace.
    .PARAMETER Context
        The Host-owned context prepared for this Turn.
    .PARAMETER Bridge
        The existing approval rendezvous.
    .PARAMETER TimeoutSeconds
        Maximum operator wait for one action.
    .OUTPUTS
        System.Management.Automation.ScriptBlock
    #>
    [CmdletBinding()]
    [OutputType([scriptblock])]
    param(
        [Parameter(Mandatory)][System.Management.Automation.Runspaces.Runspace]$Runspace,
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][AllowNull()][object]$Bridge,
        [ValidateRange(1, 86400)][int]$TimeoutSeconds = 900
    )
    if (-not (Test-DpToolCallApprovalSupport -Runspace $Runspace)) {
        throw 'This Engine does not provide the ToolCallApprover pre-dispatch contract. Use Terminal-only approval or an Engine implementing specification 120; no Tool or Model was invoked.'
    }
    if ($null -eq $Bridge) { throw 'The Host approval bridge is unavailable; no Tool was approved.' }
    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.AppendLine('param($Context, $Bridge, [int]$TimeoutSeconds)')
    foreach ($name in @('Get-DpPropertyValue', 'ConvertTo-DpTerminalExecution', 'New-DpApprovalRequest', 'Invoke-DpToolCallApproval')) {
        $command = Get-Command -Name $name -CommandType Function -ErrorAction Stop
        [void]$builder.AppendLine("function global:$name {")
        [void]$builder.AppendLine($command.Definition)
        [void]$builder.AppendLine('}')
    }
    [void]$builder.AppendLine(@'
$global:DeskPilotToolApprovalContext = $Context
$global:DeskPilotToolApprovalBridge = $Bridge
$global:DeskPilotToolApprovalTimeout = $TimeoutSeconds
$global:DeskPilotToolCallApprover = {
    param($Call)
    Invoke-DpToolCallApproval -Call $Call -Context $global:DeskPilotToolApprovalContext -Bridge $global:DeskPilotToolApprovalBridge -TimeoutSeconds $global:DeskPilotToolApprovalTimeout
}
'@)
    $setup = [powershell]::Create()
    $setup.Runspace = $Runspace
    try {
        $null = $setup.AddScript($builder.ToString()).AddArgument($Context).AddArgument($Bridge).AddArgument($TimeoutSeconds)
        $setup.Invoke() | Out-Null
        if ($setup.HadErrors) { throw 'The Engine ToolCallApprover bridge could not be initialized; dispatch was refused.' }
        $callback = $Runspace.SessionStateProxy.GetVariable('DeskPilotToolCallApprover')
        if ($callback -isnot [scriptblock]) { throw 'The Engine ToolCallApprover callback was not created; dispatch was refused.' }
        $callback
    }
    finally { $setup.Dispose() }
}
