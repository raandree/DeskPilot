function Set-DpBrowserTool {
    <#
    .SYNOPSIS
        Enables or removes DeskPilot's contained browser Tool.
    .DESCRIPTION
        Called once per Turn beside the terminal and workspace Tools, and for the
        same reason: a registered User Tool is a separate Engine category, so one
        left over from an earlier Turn keeps working after the Permission that
        justified it was switched off. Removal has to be as explicit as
        registration.

        Removal also closes any browser the previous Turn left open. A Turn that
        ends with a visible window still running would be the orphan state Stop
        exists to prevent, arrived at by a different route.
    .PARAMETER Runspace
        The idle, long-lived Engine Runspace.
    .PARAMETER Enabled
        Whether the browser Tool must be available for the next Turn.
    .PARAMETER Context
        conversationId, turnId, project, projectDomains and runtimeRoot.
    .PARAMETER TimeoutMinutes
        How long an unanswered navigation approval waits before it is denied.
    .PARAMETER Bridge
        The approval rendezvous the Tool parks on.
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

        [ValidateRange(1, 1440)]
        [int]$TimeoutMinutes = 15,

        [AllowNull()]
        [object]$Bridge
    )

    # Whether it is being switched on or off, a browser from the previous Turn
    # must not survive into this one.
    Close-DpBrowserSession -Runspace $Runspace

    if ($Enabled) {
        return Initialize-DpBrowserTool -Runspace $Runspace -Context $Context -TimeoutMinutes $TimeoutMinutes -Bridge $Bridge
    }

    $shell = [powershell]::Create()
    $shell.Runspace = $Runspace
    try {
        # Unregister-ShpTool only warns about a name it does not hold, so removal
        # is safe on a runspace that never had the tool.
        $null = $shell.AddScript(@'
foreach ($name in @('DeskPilotBrowserContext', 'DeskPilotBrowserBridge', 'DeskPilotBrowserState', 'DeskPilotBrowserTimeoutMinutes')) {
    Set-Variable -Name $name -Scope Global -Value $null
}
Unregister-ShpTool -Name 'browser_page' -Confirm:$false -WarningAction SilentlyContinue
'@)
        $shell.Invoke() | Out-Null
        if ($shell.HadErrors) {
            $firstError = $shell.Streams.Error | Select-Object -First 1
            throw $(if ($firstError) { $firstError.ToString() } else { 'Could not remove the browser tool.' })
        }
    }
    finally {
        $shell.Dispose()
    }

    $true
}
