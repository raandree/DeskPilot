function Get-DpSchedulePayload {
    <#
    .SYNOPSIS
        Builds the GET /api/schedules response.
    .DESCRIPTION
        Reports every schedule with its next run and last outcome, how deep the
        run queue is, and which run currently holds the Engine. The prompt is part
        of the view because it is what the user wrote and has to be able to edit.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $state = $script:DeskPilot
    $store = if ($state.ContainsKey('Schedules') -and $state.Schedules) { $state.Schedules } else { @{ schedules = @(); queue = @(); claim = $null } }

    $queued = @{}
    foreach ($entry in @($store.queue)) {
        $queued[[string]$entry.scheduleId] = $entry
    }

    $schedules = @(foreach ($schedule in @($store.schedules)) {
            @{
                id              = [string]$schedule.id
                name            = [string]$schedule.name
                prompt          = [string]$schedule.prompt
                recurrence      = [string]$schedule.recurrence
                timeOfDay       = [string]$schedule.timeOfDay
                weekdays        = @($schedule.weekdays)
                runAtUtc        = $schedule.runAtUtc
                timeZoneId      = [string]$schedule.timeZoneId
                projectId       = $schedule.projectId
                agent           = $schedule.agent
                model           = $schedule.model
                enabled         = [bool]$schedule.enabled
                collisionPolicy = [string]$schedule.collisionPolicy
                permissionMode  = [string]$schedule.permissionMode
                catchUpMinutes  = [int]$schedule.catchUpMinutes
                expiryMinutes   = [int]$schedule.expiryMinutes
                nextRunUtc      = $schedule.nextRunUtc
                lastRun         = $schedule.lastRun
                history         = @($schedule.history)
                queued          = $queued.ContainsKey([string]$schedule.id)
            }
        })

    @{
        schedules  = @($schedules)
        queueDepth = @($store.queue).Count
        running    = $store.claim
        revision   = [int]$state.SchedulesRevision
    }
}
