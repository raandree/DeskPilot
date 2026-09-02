function Update-DpDiagnosticCheckState {
    <#
    .SYNOPSIS
        Reaps a completed diagnostic self-check job.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Reaps a read-only job and updates transient Host Server state.')]
    param()

    $diagnostics = $script:DeskPilot.Diagnostics
    $job = $diagnostics.CheckJob
    if (-not $job -or $job.State -in @('NotStarted', 'Running')) { return }

    try {
        $result = @($job | Receive-Job -ErrorAction SilentlyContinue) | Select-Object -Last 1
        $checks = @(Get-DpPropertyValue -InputObject $result -Name @('checks') -Default @())
        if (-not $result -or $checks.Count -eq 0) {
            $reason = @($job.ChildJobs | ForEach-Object { $_.JobStateInfo.Reason } | Where-Object { $_ }) | Select-Object -First 1
            $message = if ($reason) { $reason.Message } else { 'The self-check returned no result.' }
            $result = @{
                startedUtc = $diagnostics.CheckStartedUtc
                completedUtc = [datetime]::UtcNow.ToString('o')
                overallState = 'degraded'
                versions = (New-DpDiagnosticSnapshot).versions
                checks = @(
                    New-DpDiagnosticCheck -Id 'self-check' -Label 'Self-check' -State 'degraded' `
                        -Explanation $message -Action 'Run the self-check again.'
                )
            }
        }
        $diagnostics.LastCheck = $result
        $diagnostics.LastCheckUtc = [string](Get-DpPropertyValue -InputObject $result -Name @('completedUtc') -Default ([datetime]::UtcNow.ToString('o')))
        if ($diagnostics.Log) {
            $overall = [string](Get-DpPropertyValue -InputObject $result -Name @('overallState') -Default 'degraded')
            Add-DpDiagnosticLog -Log $diagnostics.Log -Severity $(if ($overall -eq 'healthy') { 'information' } else { 'warning' }) `
                -Component 'diagnostics' -EventId 'self-check.completed' -Summary "The self-check completed with state '$overall'."
        }
    }
    catch {
        $reapError = Protect-DpDiagnosticText -Text "$($_.Exception.Message)"
        $diagnostics.LastCheck = @{
            startedUtc = $diagnostics.CheckStartedUtc
            completedUtc = [datetime]::UtcNow.ToString('o')
            overallState = 'degraded'
            versions = (New-DpDiagnosticSnapshot).versions
            checks = @(New-DpDiagnosticCheck -Id 'self-check' -Label 'Self-check' -State 'degraded' `
                    -Explanation $reapError -Action 'Run the self-check again.')
        }
        $diagnostics.LastCheckUtc = $diagnostics.LastCheck.completedUtc
    }
    finally {
        $diagnostics.Checking = $false
        $job | Remove-Job -Force -ErrorAction SilentlyContinue
        $diagnostics.CheckJob = $null
    }
}