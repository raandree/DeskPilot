function Get-DpTerminalStatus {
    <#
    .SYNOPSIS
        Projects runtime observations into a secret-free Diagnostics response.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    Update-DpTerminalPreparation
    $state = $script:DeskPilot
    $runtime = Get-DpPropertyValue -InputObject $state -Name 'TerminalRuntime'
    $job = Get-DpPropertyValue -InputObject $state -Name 'TerminalSetupJob'
    if (-not $runtime) { $runtime = Get-DpTerminalRuntime -DataDirectory $state.DataDir }
    @{
        ready = [bool](Get-DpPropertyValue -InputObject $runtime -Name 'ready' -Default $false)
        state = [string](Get-DpPropertyValue -InputObject $runtime -Name 'state' -Default 'unavailable')
        image = [string](Get-DpPropertyValue -InputObject $runtime -Name 'image' -Default '')
        powerShellVersion = [string](Get-DpPropertyValue -InputObject $runtime -Name 'powerShellVersion' -Default '')
        dockerVersion = [string](Get-DpPropertyValue -InputObject $runtime -Name 'dockerVersion' -Default '')
        orphanCount = [int](Get-DpPropertyValue -InputObject $runtime -Name 'orphanCount' -Default 0)
        issues = @(Get-DpPropertyValue -InputObject $runtime -Name 'issues' -Default @() | ForEach-Object { ([string]$_).Substring(0, [math]::Min(400, ([string]$_).Length)) })
        preparing = [bool]($job -and $job.State -in @('NotStarted', 'Running'))
        turnRunning = [bool]$state.TurnRunning
    }
}
