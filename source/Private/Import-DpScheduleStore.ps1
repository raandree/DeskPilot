function Import-DpScheduleStore {
    <#
    .SYNOPSIS
        Loads scheduled work from disk.
    .DESCRIPTION
        Reads schedules.json into a store of schedules, the pending run queue and
        the claim of a run that was in flight when the Host Server last stopped.
        A missing, unreadable or corrupt file yields an empty store rather than an
        error, and one invalid row is dropped without taking the valid rows with
        it - a schedule that cannot be parsed must not be able to stop DeskPilot
        from starting.
    .PARAMETER Directory
        The per-user data directory.
    .OUTPUTS
        System.Collections.Hashtable with schedules, queue and claim.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Directory
    )

    $store = @{ schedules = @(); queue = @(); claim = $null }
    $path = Join-Path $Directory 'schedules.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $store }

    try { $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop } catch { return $store }
    if ([string]::IsNullOrWhiteSpace($raw)) { return $store }
    try { $parsed = $raw | ConvertFrom-Json -ErrorAction Stop } catch { return $store }
    if ($null -eq $parsed) { return $store }

    $store.schedules = @(foreach ($entry in @(Get-DpPropertyValue -InputObject $parsed -Name @('schedules') -Default @())) {
            if (-not $entry) { continue }
            try { ConvertTo-DpSchedule -InputObject $entry } catch { $null = $_ }
        })

    $store.queue = @(foreach ($entry in @(Get-DpPropertyValue -InputObject $parsed -Name @('queue') -Default @())) {
            if (-not $entry) { continue }
            $scheduleId = [string](Get-DpPropertyValue -InputObject $entry -Name @('scheduleId') -Default '')
            if ([string]::IsNullOrWhiteSpace($scheduleId)) { continue }
            @{
                scheduleId  = $scheduleId
                dueUtc      = ConvertTo-DpIsoString -Value (Get-DpPropertyValue -InputObject $entry -Name @('dueUtc') -Default $null)
                queuedUtc   = ConvertTo-DpIsoString -Value (Get-DpPropertyValue -InputObject $entry -Name @('queuedUtc') -Default $null)
                source      = [string](Get-DpPropertyValue -InputObject $entry -Name @('source') -Default 'schedule')
                triggerPath = [string](Get-DpPropertyValue -InputObject $entry -Name @('triggerPath') -Default '')
            }
        })

    $claim = Get-DpPropertyValue -InputObject $parsed -Name @('claim') -Default $null
    if ($claim) {
        $claimId = [string](Get-DpPropertyValue -InputObject $claim -Name @('scheduleId') -Default '')
        if (-not [string]::IsNullOrWhiteSpace($claimId)) {
            $store.claim = @{
                scheduleId = $claimId
                startedUtc = ConvertTo-DpIsoString -Value (Get-DpPropertyValue -InputObject $claim -Name @('startedUtc') -Default $null)
            }
        }
    }

    $store
}
