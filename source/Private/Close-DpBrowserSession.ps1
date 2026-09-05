function Close-DpBrowserSession {
    <#
    .SYNOPSIS
        Closes a browser left open in the Engine Runspace.
    .DESCRIPTION
        The session lives in a runspace global, so it outlives the Tool call that
        created it and has to be closed from outside. Called when a Turn ends and
        when the Tool is re-registered, so a browser cannot survive into a Turn
        that did not ask for one - and cannot survive a Permission being switched
        off, which would leave a window running that nothing in the UI accounts
        for.

        Failures are swallowed deliberately. This runs on the way out, and a
        runspace that is already broken must not turn cleanup into the error the
        user sees instead of the real one.
    .PARAMETER Runspace
        The Engine Runspace that may hold a session.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Runspaces.Runspace]$Runspace
    )

    $shell = [powershell]::Create()
    $shell.Runspace = $Runspace
    try {
        $null = $shell.AddScript(@'
$state = Get-Variable -Name DeskPilotBrowserState -Scope Global -ErrorAction SilentlyContinue
if ($state -and $state.Value -and $state.Value.session) {
    try { Stop-DpBrowserSession -Session $state.Value.session -Confirm:$false } catch { $null = $_ }
    $state.Value.session = $null
}
'@)
        $shell.Invoke() | Out-Null
    }
    catch { $null = $_ }
    finally {
        $shell.Dispose()
    }
}
