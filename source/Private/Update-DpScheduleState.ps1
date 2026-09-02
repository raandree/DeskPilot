function Update-DpScheduleState {
    <#
    .SYNOPSIS
        Advances scheduled work by one tick.
    .DESCRIPTION
        Called from the accept loop's idle tick (with -AllowTurn, the one caller
        with no Turn on the stack) and from the routes that create or edit a
        schedule (without it). One tick does four things, in order:

        1. Reports a run that was claimed but never finished, exactly once. The
           claim is persisted before a run starts, so a restart can tell "this
           never finished" from "this never started" and reports the job instead
           of quietly repeating work that may already have written files.
        2. Expires queued runs that waited longer than their own window, and
           drops entries whose schedule has since been deleted.
        3. Turns due occurrences into at most one queued run per schedule. A run
           later than the schedule's catch-up window is recorded as missed rather
           than run hours after the moment it was meant for.
        4. Starts the head of the queue when the Engine is idle.

        There is one Engine Runspace and one active Turn, so the queue is the
        whole concurrency model: nothing here ever starts a second Turn, and a
        tick that finds a Turn running does bookkeeping only.
    .PARAMETER AllowTurn
        Permit starting a queued run. Passed only by the accept loop.
    .PARAMETER Now
        The reference instant, in UTC. Injectable so schedule arithmetic, sleep,
        and clock jumps are testable.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Pump step driven by the accept loop; ShouldProcess is not meaningful on the accept thread.')]
    param(
        [switch]$AllowTurn,

        [datetime]$Now = [datetime]::UtcNow
    )

    $state = $script:DeskPilot
    if (-not $state -or -not ($state -is [hashtable]) -or -not $state.ContainsKey('Schedules') -or -not $state.Schedules) { return }

    $store = $state.Schedules
    $nowUtc = if ($Now.Kind -eq [DateTimeKind]::Utc) { $Now } else { $Now.ToUniversalTime() }
    $dirty = $false
    $maxQueue = 20
    $maxHistory = 20

    $parseUtc = {
        param([object]$Value)
        if ($null -eq $Value) { return $null }
        if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
        $parsed = [datetime]::MinValue
        $ok = [datetime]::TryParse([string]$Value, [cultureinfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal,
            [ref]$parsed)
        if (-not $ok) { return $null }
        [datetime]::SpecifyKind($parsed, [DateTimeKind]::Utc)
    }

    $record = {
        param([hashtable]$Schedule, [string]$Outcome, [string]$Detail, [string]$ConversationId)
        $entry = @{
            outcome        = $Outcome
            detail         = $Detail
            atUtc          = $nowUtc.ToString('o')
            conversationId = [string]$ConversationId
        }
        $Schedule.lastRun = $entry
        $history = @(@($Schedule.history) + $entry)
        if ($history.Count -gt $maxHistory) { $history = @($history[($history.Count - $maxHistory)..($history.Count - 1)]) }
        $Schedule.history = @($history)
        try {
            if ($state.ContainsKey('Diagnostics') -and $state.Diagnostics -and $state.Diagnostics.Log) {
                Add-DpDiagnosticLog -Log $state.Diagnostics.Log -Severity $(if ($Outcome -eq 'completed') { 'information' } else { 'warning' }) `
                    -Component 'schedule' -EventId "schedule.$Outcome" -Summary "Schedule '$($Schedule.name)': $Outcome."
            }
        }
        catch { $null = $_ }
    }

    # 1. An unfinished claim from a previous launch.
    if ($store.claim) {
        $claimedId = [string]$store.claim.scheduleId
        foreach ($schedule in @($store.schedules)) {
            if ($schedule.id -ne $claimedId) { continue }
            & $record $schedule 'interrupted' 'DeskPilot stopped while this run was in progress, so it was not repeated.' ''
        }
        $store.claim = $null
        $dirty = $true
    }

    # 2. Expiry and orphaned queue entries.
    if (@($store.queue).Count -gt 0) {
        $kept = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($entry in @($store.queue)) {
            $schedule = @($store.schedules | Where-Object { $_.id -eq $entry.scheduleId }) | Select-Object -First 1
            if (-not $schedule) { $dirty = $true; continue }
            $queuedUtc = & $parseUtc $entry.queuedUtc
            $expiry = [int]$schedule.expiryMinutes
            if ($queuedUtc -and ($nowUtc - $queuedUtc).TotalMinutes -gt $expiry) {
                & $record $schedule 'expired' "The run waited longer than $expiry minute(s) and was dropped." ''
                $dirty = $true
                continue
            }
            $kept.Add($entry)
        }
        if ($kept.Count -ne @($store.queue).Count) { $store.queue = @($kept) }
    }

    # 3. Due occurrences.
    foreach ($schedule in @($store.schedules)) {
        if (-not $schedule.enabled) { continue }

        $nextUtc = & $parseUtc $schedule.nextRunUtc
        if (-not $nextUtc) {
            $computed = Get-DpScheduleNextRun -Recurrence $schedule.recurrence -TimeOfDay $schedule.timeOfDay `
                -Weekday @($schedule.weekdays) -RunAtUtc $schedule.runAtUtc -After $nowUtc -TimeZoneId $schedule.timeZoneId
            $schedule.nextRunUtc = if ($computed) { $computed.ToString("yyyy-MM-ddTHH:mm:ss'Z'") } else { $null }
            if (-not $computed -and $schedule.recurrence -eq 'once') { $schedule.enabled = $false }
            $dirty = $true
            continue
        }
        if ($nextUtc -gt $nowUtc) { continue }

        $lateMinutes = ($nowUtc - $nextUtc).TotalMinutes
        $following = Get-DpScheduleNextRun -Recurrence $schedule.recurrence -TimeOfDay $schedule.timeOfDay `
            -Weekday @($schedule.weekdays) -RunAtUtc $schedule.runAtUtc -After $nowUtc -TimeZoneId $schedule.timeZoneId
        $schedule.nextRunUtc = if ($following) { $following.ToString("yyyy-MM-ddTHH:mm:ss'Z'") } else { $null }
        if (-not $following -and $schedule.recurrence -eq 'once') { $schedule.enabled = $false }
        $dirty = $true

        if ($lateMinutes -gt [int]$schedule.catchUpMinutes) {
            & $record $schedule 'missed' "DeskPilot was not running at $($nextUtc.ToString("yyyy-MM-dd HH:mm")) UTC and the catch-up window has passed." ''
            continue
        }

        $pending = @($store.queue | Where-Object { $_.scheduleId -eq $schedule.id })
        if ($pending.Count -gt 0) {
            & $record $schedule 'coalesced' 'A run for this schedule was already waiting, so this occurrence joined it.' ''
            continue
        }
        if (@($store.queue).Count -ge $maxQueue) {
            & $record $schedule 'skipped' "The run queue is full ($maxQueue waiting), so this occurrence was dropped." ''
            continue
        }
        if ($schedule.collisionPolicy -eq 'skip' -and ($state.TurnRunning -or @($store.queue).Count -gt 0)) {
            & $record $schedule 'skipped' 'DeskPilot was busy and this schedule is set to skip a clash.' ''
            continue
        }

        $store.queue = @(@($store.queue) + @{
                scheduleId = [string]$schedule.id
                dueUtc     = $nextUtc.ToString("yyyy-MM-ddTHH:mm:ss'Z'")
                queuedUtc  = $nowUtc.ToString("yyyy-MM-ddTHH:mm:ss'Z'")
                source     = 'schedule'
            })
    }

    # 4. Start the head of the queue.
    if ($AllowTurn -and -not $state.TurnRunning -and @($store.queue).Count -gt 0) {
        $entry = @($store.queue)[0]
        $store.queue = @(@($store.queue) | Select-Object -Skip 1)
        $schedule = @($store.schedules | Where-Object { $_.id -eq $entry.scheduleId }) | Select-Object -First 1
        $dirty = $true

        if ($schedule) {
            $store.claim = @{ scheduleId = [string]$schedule.id; startedUtc = $nowUtc.ToString('o') }
            if ($state.DataDir) { Save-DpScheduleStore -Store $store -Directory $state.DataDir -Confirm:$false }

            $result = $null
            try { $result = Invoke-DpScheduledTurn -Schedule $schedule }
            catch { $result = @{ outcome = 'failed'; detail = "$_"; conversationId = '' } }
            finally { $store.claim = $null }

            $outcome = [string](Get-DpPropertyValue -InputObject $result -Name @('outcome') -Default 'failed')
            $detail = [string](Get-DpPropertyValue -InputObject $result -Name @('detail') -Default '')
            $conversationId = [string](Get-DpPropertyValue -InputObject $result -Name @('conversationId') -Default '')
            & $record $schedule $outcome $detail $conversationId
        }
    }

    if ($dirty) {
        $state.SchedulesRevision = [int]$state.SchedulesRevision + 1
        if ($state.DataDir) { Save-DpScheduleStore -Store $store -Directory $state.DataDir -Confirm:$false }
    }
}
