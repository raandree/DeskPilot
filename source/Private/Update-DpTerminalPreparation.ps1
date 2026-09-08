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
        $preparationError = $_
        $missingDocker = ($preparationError.FullyQualifiedErrorId -split ',', 2)[0] -eq 'DockerDesktopNotInstalled'
        $issues = if ($missingDocker) {
            Protect-DpDiagnosticText -Text $preparationError.Exception.Message -MaxLength 400
        }
        else {
            Protect-DpDiagnosticText -Text "Runtime preparation failed: $($preparationError.Exception.Message)" -MaxLength 400
            'Check Docker Desktop, available disk space and access to the verified runtime download sources, then retry.'
        }
        $state.TerminalRuntime = @{
            ready = $false
            state = if ($missingDocker) { 'unavailable' } else { 'degraded' }
            orphanCount = 0
            issues = @($issues)
        }
    }
    finally {
        $job | Remove-Job -Force
        $state.TerminalSetupJob = $null
    }
}
