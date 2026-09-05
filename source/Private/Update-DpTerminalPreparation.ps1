function Update-DpTerminalPreparation {
    <#
    .SYNOPSIS
        Reaps completed runtime preparation without blocking the Host Server.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param()

    $state = $script:DeskPilot
    $job = Get-DpPropertyValue -InputObject $state -Name 'TerminalSetupJob'
    if (-not $job -or $job.State -in @('NotStarted', 'Running')) { return }
    try {
        $result = @($job | Receive-Job -ErrorAction Stop) | Select-Object -Last 1
        if ($job.State -ne 'Completed' -or -not $result.image) { throw 'Runtime preparation did not complete.' }
        $state.TerminalRuntime = Get-DpTerminalRuntime -DataDirectory $state.DataDir -Probe
    }
    catch {
        $state.TerminalRuntime = @{
            ready = $false; state = 'degraded'; orphanCount = 0
            issues = @('Runtime preparation failed. Check Docker Desktop, available disk space and access to the verified runtime download sources, then retry.')
        }
    }
    finally {
        $job | Remove-Job -Force
        $state.TerminalSetupJob = $null
    }
}
