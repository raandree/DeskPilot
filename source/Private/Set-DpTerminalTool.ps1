function Set-DpTerminalTool {
    <#
    .SYNOPSIS
        Enables or removes DeskPilot's approval-gated terminal Tool.
    .DESCRIPTION
        Called once per Turn beside Set-DpWorkspaceTool, for the same reason: a
        registered User Tool is a separate Engine category, so a Tool left over
        from a previous Turn keeps working after the Setting that justified it was
        switched off. Removal has to be as explicit as registration.

        The gated Tool is registered only while all three hold: per-call approval
        is on, Terminal Permission is on, and Your Tools is on. Terminal off means
        no terminal at all, which is stricter than approval and must stay that
        way. Your Tools off would strip the gated Tool from the Turn, so approval
        stands down rather than leaving -DisableTerminal as the only effect.
    .PARAMETER Runspace
        The idle, long-lived Engine Runspace.
    .PARAMETER Enabled
        Whether the gated Tool must be available for the next Turn.
    .PARAMETER Context
        conversationId, turnId, project and workingDirectory for this Turn.
    .PARAMETER SafeCommand
        The effective safe-list: shipped entries plus validated user additions.
    .PARAMETER TimeoutMinutes
        How long an unanswered approval waits before it is denied.
    .PARAMETER Bridge
        The approval bridge instance the Tool blocks on.
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Runspaces.Runspace]$Runspace,

        [Parameter(Mandatory)]
        [bool]$Enabled,

        [hashtable]$Context = @{},

        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$SafeCommand,

        [ValidateRange(1, 1440)]
        [int]$TimeoutMinutes = 15,

        [object]$Bridge
    )

    if ($Enabled) {
        $registerParams = @{
            Runspace       = $Runspace
            Context        = $Context
            SafeCommand    = @($SafeCommand)
            TimeoutMinutes = $TimeoutMinutes
            Bridge         = $Bridge
        }
        return Initialize-DpTerminalTool @registerParams
    }

    $shell = [powershell]::Create()
    $shell.Runspace = $Runspace
    try {
        # Unregister-ShpTool only warns about a name it does not hold, so removal
        # is safe on a runspace that never had the tool. The globals are cleared
        # too: a stale executor left behind would be a working terminal with
        # nothing registered to reach it.
        $null = $shell.AddScript(@'
foreach ($name in @('DeskPilotTerminalExecutor', 'DeskPilotApprovalBridge', 'DeskPilotApprovalContext', 'DeskPilotSafeCommand')) {
    Set-Variable -Name $name -Scope Global -Value $null
}
Unregister-ShpTool -Name 'run_terminal_command' -Confirm:$false -WarningAction SilentlyContinue
'@)
        $shell.Invoke() | Out-Null
        if ($shell.HadErrors) {
            $firstError = $shell.Streams.Error | Select-Object -First 1
            throw $(if ($firstError) { $firstError.ToString() } else { 'Could not remove the approval-gated terminal tool.' })
        }
    }
    finally {
        $shell.Dispose()
    }

    $true
}
