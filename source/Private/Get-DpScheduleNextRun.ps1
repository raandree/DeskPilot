function Get-DpScheduleNextRun {
    <#
    .SYNOPSIS
        Computes the next run instant of a schedule, in UTC.
    .DESCRIPTION
        Pure and deterministic: given a recurrence, a local time of day, a time
        zone and a reference instant, it returns the first occurrence strictly
        after that instant, or nothing when the schedule has no further run.

        Wall-clock arithmetic happens in the schedule's own zone, because "every
        weekday at 08:00" is a statement about a clock on a wall, not about UTC.
        The two daylight-saving edges are decided here rather than left to chance:

        - A local time the spring-forward gap deletes never occurs, so the run
          moves to the first instant after the gap instead of being skipped for
          the day.
        - A local time the autumn overlap repeats occurs twice, so the first
          (still on summer time) occurrence wins and the job runs once.
    .PARAMETER Recurrence
        once, daily or weekly.
    .PARAMETER TimeOfDay
        Local time of day as HH:mm, for daily and weekly schedules.
    .PARAMETER Weekday
        Selected weekdays for a weekly schedule, 0 (Sunday) through 6.
    .PARAMETER RunAtUtc
        The single instant of a one-time schedule.
    .PARAMETER After
        The reference instant, in UTC. The result is strictly after it.
    .PARAMETER TimeZoneId
        The schedule's time zone. The host zone is used when it is absent.
    .OUTPUTS
        System.DateTime (UTC), or nothing when there is no further run.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('once', 'daily', 'weekly', 'onFileChange')]
        [string]$Recurrence,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$TimeOfDay,

        [AllowNull()]
        [AllowEmptyCollection()]
        [int[]]$Weekday = @(),

        [AllowNull()]
        [object]$RunAtUtc,

        [Parameter(Mandatory)]
        [datetime]$After,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$TimeZoneId
    )

    $afterUtc = if ($After.Kind -eq [DateTimeKind]::Utc) { $After } else { $After.ToUniversalTime() }

    # A file trigger has no clock; its next run is decided by Get-DpAutomationEvent.
    if ($Recurrence -eq 'onFileChange') { return $null }

    if ($Recurrence -eq 'once') {
        if ($null -eq $RunAtUtc) { return $null }
        $instant = [datetime]::MinValue
        $parsed = [datetime]::TryParse(
            [string]$RunAtUtc, [cultureinfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal,
            [ref]$instant)
        if (-not $parsed) { return $null }
        $instant = [datetime]::SpecifyKind($instant, [DateTimeKind]::Utc)
        if ($instant -gt $afterUtc) { return $instant }
        return $null
    }

    if ([string]::IsNullOrWhiteSpace($TimeOfDay) -or $TimeOfDay -notmatch '^([01][0-9]|2[0-3]):([0-5][0-9])$') { return $null }
    $hour = [int]$Matches[1]
    $minute = [int]$Matches[2]

    $zone = [System.TimeZoneInfo]::Local
    if (-not [string]::IsNullOrWhiteSpace($TimeZoneId)) {
        try { $zone = [System.TimeZoneInfo]::FindSystemTimeZoneById($TimeZoneId) } catch { $zone = [System.TimeZoneInfo]::Local }
    }

    $days = @($Weekday | ForEach-Object { [int]$_ })
    if ($Recurrence -eq 'weekly' -and $days.Count -eq 0) { return $null }

    $localAfter = [System.TimeZoneInfo]::ConvertTimeFromUtc($afterUtc, $zone)

    # 8 days is enough for both recurrences; the extra day covers a candidate the
    # gap adjustment pushes past midnight.
    for ($offset = 0; $offset -le 8; $offset++) {
        $date = $localAfter.Date.AddDays($offset)
        if ($Recurrence -eq 'weekly' -and $days -notcontains [int]$date.DayOfWeek) { continue }

        $local = [datetime]::SpecifyKind($date.AddHours($hour).AddMinutes($minute), [DateTimeKind]::Unspecified)

        $guard = 0
        while ($zone.IsInvalidTime($local) -and $guard -lt 240) {
            $local = $local.AddMinutes(1)
            $guard++
        }

        if ($zone.IsAmbiguousTime($local)) {
            # The largest offset is the first of the two occurrences.
            $chosen = @($zone.GetAmbiguousTimeOffsets($local) | Sort-Object -Descending)[0]
            $candidate = [System.DateTimeOffset]::new($local, $chosen).UtcDateTime
        }
        else {
            $candidate = [System.TimeZoneInfo]::ConvertTimeToUtc($local, $zone)
        }
        $candidate = [datetime]::SpecifyKind($candidate, [DateTimeKind]::Utc)

        if ($candidate -gt $afterUtc) { return $candidate }
    }

    $null
}
