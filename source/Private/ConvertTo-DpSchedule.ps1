function ConvertTo-DpSchedule {
    <#
    .SYNOPSIS
        Validates and normalizes one scheduled-work record.
    .DESCRIPTION
        Reads a schedule from Settings-shaped input (a hashtable in memory, a
        PSCustomObject once it has been round-tripped through JSON) and returns a
        normalized hashtable. Throws on an invalid field so a route can map the
        failure to an HTTP 400 - a schedule silently dropped or silently repaired
        would report as saved and then never run, or run at a time nobody chose.

        Everything a run needs is captured on the record. What the run is allowed
        to do is not: Permissions are read live at execution and can only be
        narrowed there, never widened (see Invoke-DpScheduledTurn).
    .PARAMETER InputObject
        The schedule to normalize.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$InputObject
    )

    if ($null -eq $InputObject) { throw 'A schedule is required.' }

    $read = {
        param([string]$Name, [object]$Default)
        Get-DpPropertyValue -InputObject $InputObject -Name @($Name) -Default $Default
    }

    $id = [string](& $read 'id' '')
    if ([string]::IsNullOrWhiteSpace($id)) { $id = New-DpId -Prefix 'sch' }

    $name = ([string](& $read 'name' '')).Trim()
    if ([string]::IsNullOrWhiteSpace($name)) { throw 'A schedule needs a name.' }
    if ($name.Length -gt 80) { throw 'A schedule name must be 80 characters or fewer.' }

    $prompt = ([string](& $read 'prompt' '')).Trim()
    if ([string]::IsNullOrWhiteSpace($prompt)) { throw 'A schedule needs a prompt.' }
    if ($prompt.Length -gt 8000) { throw 'A schedule prompt must be 8000 characters or fewer.' }

    $recurrence = ([string](& $read 'recurrence' 'daily')).Trim().ToLowerInvariant()
    if (@('once', 'daily', 'weekly') -notcontains $recurrence) {
        throw "Invalid recurrence '$recurrence'. Allowed: once, daily, weekly."
    }

    $timeOfDay = ([string](& $read 'timeOfDay' '')).Trim()
    $runAtUtc = $null
    $weekdays = @()

    if ($recurrence -eq 'once') {
        $rawInstant = & $read 'runAtUtc' $null
        $instant = [datetime]::MinValue
        $ok = $null -ne $rawInstant -and [datetime]::TryParse(
            [string]$rawInstant, [cultureinfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal,
            [ref]$instant)
        if (-not $ok) { throw 'A one-time schedule needs a runAtUtc instant.' }
        $runAtUtc = [datetime]::SpecifyKind($instant, [DateTimeKind]::Utc).ToString('o')
        $timeOfDay = ''
    }
    else {
        if ($timeOfDay -notmatch '^([01][0-9]|2[0-3]):([0-5][0-9])$') {
            throw "Invalid timeOfDay '$timeOfDay'. Use HH:mm in 24-hour form."
        }
        if ($recurrence -eq 'weekly') {
            $weekdays = @(@(& $read 'weekdays' @()) | ForEach-Object {
                    $day = [int]$_
                    if ($day -lt 0 -or $day -gt 6) { throw "Invalid weekday '$day'. Use 0 (Sunday) through 6." }
                    $day
                } | Sort-Object -Unique)
            if ($weekdays.Count -eq 0) { throw 'A weekly schedule needs at least one weekday.' }
        }
    }

    $timeZoneId = ([string](& $read 'timeZoneId' '')).Trim()
    if ([string]::IsNullOrWhiteSpace($timeZoneId)) { $timeZoneId = [System.TimeZoneInfo]::Local.Id }
    else {
        try { $null = [System.TimeZoneInfo]::FindSystemTimeZoneById($timeZoneId) }
        catch { throw "Unknown time zone '$timeZoneId'." }
    }

    $collisionPolicy = ([string](& $read 'collisionPolicy' 'queue')).Trim().ToLowerInvariant()
    if (@('queue', 'skip') -notcontains $collisionPolicy) {
        throw "Invalid collisionPolicy '$collisionPolicy'. Allowed: queue, skip."
    }

    $permissionMode = ([string](& $read 'permissionMode' 'safe')).Trim().ToLowerInvariant()
    if (@('safe', 'live') -notcontains $permissionMode) {
        throw "Invalid permissionMode '$permissionMode'. Allowed: safe, live."
    }

    $catchUpMinutes = [int](& $read 'catchUpMinutes' 120)
    if ($catchUpMinutes -lt 0 -or $catchUpMinutes -gt 1440) { throw 'catchUpMinutes must be between 0 and 1440.' }

    $expiryMinutes = [int](& $read 'expiryMinutes' 60)
    if ($expiryMinutes -lt 1 -or $expiryMinutes -gt 1440) { throw 'expiryMinutes must be between 1 and 1440.' }

    $optional = {
        param([string]$Name)
        $value = Get-DpPropertyValue -InputObject $InputObject -Name @($Name) -Default $null
        if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) { return $null }
        ([string]$value).Trim()
    }

    $lastRun = $null
    $rawLastRun = & $read 'lastRun' $null
    if ($rawLastRun) {
        $lastRun = @{
            outcome        = [string](Get-DpPropertyValue -InputObject $rawLastRun -Name @('outcome') -Default 'unknown')
            detail         = [string](Get-DpPropertyValue -InputObject $rawLastRun -Name @('detail') -Default '')
            atUtc          = ConvertTo-DpIsoString -Value (Get-DpPropertyValue -InputObject $rawLastRun -Name @('atUtc') -Default $null)
            conversationId = [string](Get-DpPropertyValue -InputObject $rawLastRun -Name @('conversationId') -Default '')
        }
    }

    $history = @(foreach ($entry in @(& $read 'history' @())) {
            if (-not $entry) { continue }
            @{
                outcome        = [string](Get-DpPropertyValue -InputObject $entry -Name @('outcome') -Default 'unknown')
                detail         = [string](Get-DpPropertyValue -InputObject $entry -Name @('detail') -Default '')
                atUtc          = ConvertTo-DpIsoString -Value (Get-DpPropertyValue -InputObject $entry -Name @('atUtc') -Default $null)
                conversationId = [string](Get-DpPropertyValue -InputObject $entry -Name @('conversationId') -Default '')
            }
        })
    if ($history.Count -gt 20) { $history = @($history[($history.Count - 20)..($history.Count - 1)]) }

    @{
        id              = $id
        name            = $name
        prompt          = $prompt
        recurrence      = $recurrence
        timeOfDay       = $timeOfDay
        weekdays        = @($weekdays)
        runAtUtc        = $runAtUtc
        timeZoneId      = $timeZoneId
        projectId       = & $optional 'projectId'
        agent           = & $optional 'agent'
        model           = & $optional 'model'
        enabled         = [bool](& $read 'enabled' $true)
        collisionPolicy = $collisionPolicy
        permissionMode  = $permissionMode
        catchUpMinutes  = $catchUpMinutes
        expiryMinutes   = $expiryMinutes
        nextRunUtc      = ConvertTo-DpIsoString -Value (& $read 'nextRunUtc' $null)
        lastRun         = $lastRun
        history         = @($history)
        createdUtc      = (ConvertTo-DpIsoString -Value (& $read 'createdUtc' $null)) ?? ([datetime]::UtcNow.ToString('o'))
        updatedUtc      = (ConvertTo-DpIsoString -Value (& $read 'updatedUtc' $null)) ?? ([datetime]::UtcNow.ToString('o'))
    }
}
