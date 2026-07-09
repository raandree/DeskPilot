function Restart-DpHost {
    <#
    .SYNOPSIS
        Relaunches DeskPilot in a fresh process and signals the current one to stop.
    .DESCRIPTION
        The only safe way to apply a DeskPilot host update: the running module
        cannot hot-swap its own executing code in-process (re-importing it would
        repoint the route handlers to a fresh module scope with no server state and
        break the live server). So this starts a new DeskPilot process - which
        imports the newest installed DeskPilot and ShellPilot - and then sets
        StopRequested so the accept loop breaks and the current process winds down.

        The new instance uses the same data directory (so Conversations carry over)
        and opens its own browser tab on a fresh port. The launcher is injectable
        for testing. Never throws; returns a status hashtable. The current process
        is only signalled to stop once the new instance has been launched, so a
        launch failure leaves the running server untouched.
    .PARAMETER Launcher
        A script block that starts the replacement process. Defaults to spawning a
        new PowerShell that imports DeskPilot with -Force and runs Start-DeskPilot.
        Overridable for testing.
    .OUTPUTS
        System.Collections.Hashtable with keys Ok, Launched, Error.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Consent is obtained in the SPA before this is called; a ShouldProcess prompt would hang the headless Host Server.')]
    param(
        [scriptblock]$Launcher
    )

    $result = @{ Ok = $false; Launched = $false; Error = $null }

    if (-not $Launcher) {
        $dataDir = if ($script:DeskPilot) { $script:DeskPilot.DataDir } else { $null }
        $Launcher = {
            # Resolve the current PowerShell executable so the relaunch works
            # regardless of how DeskPilot was started; fall back to 'pwsh' on PATH.
            $exe = [System.Environment]::ProcessPath
            if ([string]::IsNullOrWhiteSpace($exe)) { $exe = 'pwsh' }
            $command = 'Import-Module DeskPilot -Force; Start-DeskPilot'
            if (-not [string]::IsNullOrWhiteSpace($dataDir)) {
                $command += " -DataDir '" + ($dataDir -replace "'", "''") + "'"
            }
            Start-Process -FilePath $exe -ArgumentList @('-NoProfile', '-NoExit', '-Command', $command)
        }.GetNewClosure()
    }

    try {
        & $Launcher
        $result.Launched = $true
        $result.Ok = $true
        if ($script:DeskPilot) { $script:DeskPilot.StopRequested = $true }
        return $result
    }
    catch {
        $result.Error = "Could not relaunch DeskPilot: $($_.Exception.Message)"
        return $result
    }
}
