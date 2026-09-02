#requires -Version 7.0

BeforeAll {
    $privateRoot = Join-Path $PSScriptRoot '..' '..' 'source' 'Private'
    Get-ChildItem -Path $privateRoot -Filter '*.ps1' | ForEach-Object { . $_.FullName }

    function Get-DpTestZone {
        # .NET 6+ resolves both IANA and Windows ids on every platform, but fall
        # back explicitly so a host without ICU still runs the suite.
        foreach ($id in @('Europe/Berlin', 'W. Europe Standard Time')) {
            try { return [System.TimeZoneInfo]::FindSystemTimeZoneById($id) } catch { $null = $_ }
        }
        $null
    }

    function New-DpTestSchedule {
        param([hashtable]$Override = @{})
        $base = @{
            name        = 'Morning review'
            prompt      = 'Review the overnight reports.'
            recurrence  = 'daily'
            timeOfDay   = '08:00'
            timeZoneId  = 'UTC'
        }
        foreach ($key in $Override.Keys) { $base[$key] = $Override[$key] }
        ConvertTo-DpSchedule -InputObject $base
    }

    function Get-DpRouteJson {
        param([System.IO.MemoryStream]$Stream)
        $response = [System.Text.Encoding]::UTF8.GetString($Stream.ToArray())
        $status = ($response -split "`r`n")[0]
        $json = $response -split "`r`n`r`n", 2 | Select-Object -Last 1 | ConvertFrom-Json
        [pscustomobject]@{ Status = $status; Json = $json }
    }
}

Describe 'Get-DpScheduleNextRun' -Tag 'Unit' {
    It 'returns the next daily occurrence after the reference instant' {
        $after = [datetime]::new(2026, 5, 4, 9, 0, 0, [DateTimeKind]::Utc)
        $next = Get-DpScheduleNextRun -Recurrence 'daily' -TimeOfDay '08:00' -After $after -TimeZoneId 'UTC'

        $next | Should -Be ([datetime]::new(2026, 5, 5, 8, 0, 0, [DateTimeKind]::Utc))
    }

    It 'returns today when the time of day is still ahead' {
        $after = [datetime]::new(2026, 5, 4, 7, 0, 0, [DateTimeKind]::Utc)
        $next = Get-DpScheduleNextRun -Recurrence 'daily' -TimeOfDay '08:00' -After $after -TimeZoneId 'UTC'

        $next | Should -Be ([datetime]::new(2026, 5, 4, 8, 0, 0, [DateTimeKind]::Utc))
    }

    It 'only lands on selected weekdays' {
        # 2026-05-04 is a Monday.
        $after = [datetime]::new(2026, 5, 4, 9, 0, 0, [DateTimeKind]::Utc)
        $next = Get-DpScheduleNextRun -Recurrence 'weekly' -TimeOfDay '08:00' -Weekday @(3) -After $after -TimeZoneId 'UTC'

        $next.DayOfWeek | Should -Be ([System.DayOfWeek]::Wednesday)
        $next | Should -Be ([datetime]::new(2026, 5, 6, 8, 0, 0, [DateTimeKind]::Utc))
    }

    It 'moves a local time that the spring-forward gap deletes to the first instant after the gap' {
        $zone = Get-DpTestZone
        if (-not $zone) { Set-ItResult -Skipped -Because 'no European time zone is available on this host'; return }

        # Central European clocks jump 02:00 -> 03:00 on 2026-03-29, so 02:30 never occurs.
        $after = [datetime]::new(2026, 3, 28, 12, 0, 0, [DateTimeKind]::Utc)
        $next = Get-DpScheduleNextRun -Recurrence 'daily' -TimeOfDay '02:30' -After $after -TimeZoneId $zone.Id

        $local = [System.TimeZoneInfo]::ConvertTimeFromUtc($next, $zone)
        $local.Date | Should -Be ([datetime]::new(2026, 3, 29))
        $local.Hour | Should -Be 3
        $local.Minute | Should -Be 0
    }

    It 'takes the first occurrence of an ambiguous local time in the fall-back overlap' {
        $zone = Get-DpTestZone
        if (-not $zone) { Set-ItResult -Skipped -Because 'no European time zone is available on this host'; return }

        # Central European clocks repeat 02:00-03:00 on 2026-10-25; 02:30 happens twice.
        $after = [datetime]::new(2026, 10, 24, 12, 0, 0, [DateTimeKind]::Utc)
        $next = Get-DpScheduleNextRun -Recurrence 'daily' -TimeOfDay '02:30' -After $after -TimeZoneId $zone.Id

        # The first occurrence is still on summer time (UTC+2), i.e. 00:30 UTC.
        $next | Should -Be ([datetime]::new(2026, 10, 25, 0, 30, 0, [DateTimeKind]::Utc))
    }

    It 'returns nothing for a one-time schedule whose instant has passed' {
        $after = [datetime]::new(2026, 5, 4, 9, 0, 0, [DateTimeKind]::Utc)
        $next = Get-DpScheduleNextRun -Recurrence 'once' -RunAtUtc '2026-05-04T08:00:00Z' -After $after

        $next | Should -BeNullOrEmpty
    }

    It 'returns the instant for a one-time schedule that is still ahead' {
        $after = [datetime]::new(2026, 5, 4, 9, 0, 0, [DateTimeKind]::Utc)
        $next = Get-DpScheduleNextRun -Recurrence 'once' -RunAtUtc '2026-05-04T10:00:00Z' -After $after

        $next | Should -Be ([datetime]::new(2026, 5, 4, 10, 0, 0, [DateTimeKind]::Utc))
    }
}

Describe 'ConvertTo-DpSchedule' -Tag 'Unit' {
    It 'normalizes a minimal daily schedule and assigns an id' {
        $schedule = New-DpTestSchedule

        $schedule.id | Should -Not -BeNullOrEmpty
        $schedule.enabled | Should -BeTrue
        $schedule.collisionPolicy | Should -Be 'queue'
        $schedule.permissionMode | Should -Be 'safe'
        $schedule.catchUpMinutes | Should -Be 120
        $schedule.expiryMinutes | Should -Be 60
    }

    It 'keeps an explicit id so an edit does not create a second schedule' {
        $schedule = New-DpTestSchedule -Override @{ id = 'sch-fixed' }
        $schedule.id | Should -Be 'sch-fixed'
    }

    It 'refuses an unknown recurrence' {
        { New-DpTestSchedule -Override @{ recurrence = 'hourly' } } | Should -Throw '*recurrence*'
    }

    It 'refuses a malformed time of day' {
        { New-DpTestSchedule -Override @{ timeOfDay = '25:00' } } | Should -Throw '*timeOfDay*'
    }

    It 'refuses a weekly schedule with no weekday' {
        { New-DpTestSchedule -Override @{ recurrence = 'weekly'; weekdays = @() } } | Should -Throw '*weekday*'
    }

    It 'accepts a weekly schedule and sorts its weekdays' {
        $schedule = New-DpTestSchedule -Override @{ recurrence = 'weekly'; weekdays = @(5, 1, 1) }
        $schedule.weekdays | Should -Be @(1, 5)
    }

    It 'refuses an empty prompt' {
        { New-DpTestSchedule -Override @{ prompt = '   ' } } | Should -Throw '*prompt*'
    }

    It 'refuses an unknown time zone rather than silently using the host zone' {
        { New-DpTestSchedule -Override @{ timeZoneId = 'Mars/Olympus' } } | Should -Throw '*time zone*'
    }

    It 'refuses an unknown permission mode' {
        { New-DpTestSchedule -Override @{ permissionMode = 'root' } } | Should -Throw '*permissionMode*'
    }
}

Describe 'Schedule store' -Tag 'Unit' {
    It 'round-trips schedules, queue and claim through disk' {
        $dir = Join-Path $TestDrive 'store-roundtrip'
        $store = @{
            schedules = @((New-DpTestSchedule -Override @{ id = 'sch-1' }))
            queue     = @(@{ scheduleId = 'sch-1'; dueUtc = '2026-05-04T08:00:00Z'; queuedUtc = '2026-05-04T08:00:01Z' })
            claim     = $null
        }
        Save-DpScheduleStore -Store $store -Directory $dir -Confirm:$false

        $loaded = Import-DpScheduleStore -Directory $dir
        @($loaded.schedules).Count | Should -Be 1
        $loaded.schedules[0].id | Should -Be 'sch-1'
        $loaded.schedules[0].prompt | Should -Be 'Review the overnight reports.'
        @($loaded.queue).Count | Should -Be 1
        $loaded.queue[0].scheduleId | Should -Be 'sch-1'
    }

    It 'returns an empty store for corrupt content instead of throwing' {
        $dir = Join-Path $TestDrive 'store-corrupt'
        $null = New-Item -ItemType Directory -Path $dir -Force
        Set-Content -LiteralPath (Join-Path $dir 'schedules.json') -Value '{ this is not json' -Encoding utf8

        $loaded = Import-DpScheduleStore -Directory $dir
        @($loaded.schedules).Count | Should -Be 0
        @($loaded.queue).Count | Should -Be 0
    }

    It 'drops an invalid schedule row without losing the valid ones' {
        $dir = Join-Path $TestDrive 'store-partial'
        $null = New-Item -ItemType Directory -Path $dir -Force
        $json = @{
            schedules = @(
                @{ id = 'good'; name = 'ok'; prompt = 'do it'; recurrence = 'daily'; timeOfDay = '08:00'; timeZoneId = 'UTC' },
                @{ id = 'bad'; name = 'broken'; prompt = 'do it'; recurrence = 'hourly' }
            )
        } | ConvertTo-Json -Depth 6
        Set-Content -LiteralPath (Join-Path $dir 'schedules.json') -Value $json -Encoding utf8

        $loaded = Import-DpScheduleStore -Directory $dir
        @($loaded.schedules).Count | Should -Be 1
        $loaded.schedules[0].id | Should -Be 'good'
    }
}

Describe 'Get-DpScopedSettings' -Tag 'Unit' {
    BeforeEach {
        $script:baseSettings = @{
            workspaceFolder   = 'C:\projects\a'
            selectedProjectId = 'p-a'
            selectedAgent     = $null
            model             = 'claude-opus-5'
            permissions       = @{ browsing = $true; file = $true; terminal = $true; askUser = $true; userTools = $true; mcp = $true }
        }
    }

    It 'overrides only the allow-listed keys and leaves the original untouched' {
        $scoped = Get-DpScopedSettings -Settings $script:baseSettings -Scope @{ workspaceFolder = 'C:\projects\b'; selectedProjectId = 'p-b' }

        $scoped.workspaceFolder | Should -Be 'C:\projects\b'
        $scoped.selectedProjectId | Should -Be 'p-b'
        $script:baseSettings.workspaceFolder | Should -Be 'C:\projects\a'
    }

    It 'narrows a permission but can never widen one' {
        $script:baseSettings.permissions.browsing = $false
        $scoped = Get-DpScopedSettings -Settings $script:baseSettings -Scope @{ permissions = @{ terminal = $false; browsing = $true } }

        $scoped.permissions.terminal | Should -BeFalse
        $scoped.permissions.browsing | Should -BeFalse
        $script:baseSettings.permissions.terminal | Should -BeTrue
    }

    It 'ignores a key that is not on the allow-list' {
        $scoped = Get-DpScopedSettings -Settings $script:baseSettings -Scope @{ maxToolIterations = 999 }
        $scoped.ContainsKey('maxToolIterations') | Should -BeFalse
    }
}

Describe 'Update-DpScheduleState' -Tag 'Unit' {
    BeforeEach {
        $script:DeskPilot = @{
            DataDir             = (Join-Path $TestDrive ('sched-' + [guid]::NewGuid().ToString('N')))
            TurnRunning         = $false
            SchedulesRevision   = 0
            Schedules           = @{ schedules = @(); queue = @(); claim = $null }
            Settings            = @{ projects = @(); permissions = @{ terminal = $true } }
            Diagnostics         = @{ Log = (New-DpDiagnosticLog -MaxEntries 50 -MaxBytes 65536) }
        }
        Mock Save-DpScheduleStore { }
        Mock Invoke-DpScheduledTurn { @{ outcome = 'completed'; detail = 'ok'; conversationId = 'c-1' } }
    }

    It 'queues a due run and recomputes the next occurrence' {
        $schedule = New-DpTestSchedule -Override @{ id = 'sch-due' }
        $schedule.nextRunUtc = '2026-05-04T08:00:00Z'
        $script:DeskPilot.Schedules.schedules = @($schedule)

        Update-DpScheduleState -Now ([datetime]::new(2026, 5, 4, 8, 0, 30, [DateTimeKind]::Utc))

        @($script:DeskPilot.Schedules.queue).Count | Should -Be 1
        $script:DeskPilot.Schedules.queue[0].scheduleId | Should -Be 'sch-due'
        $script:DeskPilot.Schedules.schedules[0].nextRunUtc | Should -Be '2026-05-05T08:00:00Z'
    }

    It 'does not queue a disabled schedule' {
        $schedule = New-DpTestSchedule -Override @{ id = 'sch-off'; enabled = $false }
        $schedule.nextRunUtc = '2026-05-04T08:00:00Z'
        $script:DeskPilot.Schedules.schedules = @($schedule)

        Update-DpScheduleState -Now ([datetime]::new(2026, 5, 4, 8, 0, 30, [DateTimeKind]::Utc))

        @($script:DeskPilot.Schedules.queue).Count | Should -Be 0
    }

    It 'coalesces a second due occurrence into the one pending entry' {
        $schedule = New-DpTestSchedule -Override @{ id = 'sch-coalesce' }
        $schedule.nextRunUtc = '2026-05-04T08:00:00Z'
        $script:DeskPilot.Schedules.schedules = @($schedule)

        Update-DpScheduleState -Now ([datetime]::new(2026, 5, 4, 8, 0, 30, [DateTimeKind]::Utc))
        $script:DeskPilot.Schedules.schedules[0].nextRunUtc = '2026-05-04T08:05:00Z'
        Update-DpScheduleState -Now ([datetime]::new(2026, 5, 4, 8, 6, 0, [DateTimeKind]::Utc))

        @($script:DeskPilot.Schedules.queue).Count | Should -Be 1
        $script:DeskPilot.Schedules.schedules[0].lastRun.outcome | Should -Be 'coalesced'
    }

    It 'skips a due run under the skip policy while another run is pending' {
        $blocking = New-DpTestSchedule -Override @{ id = 'sch-block' }
        $blocking.nextRunUtc = '2026-05-04T08:00:00Z'
        $skipper = New-DpTestSchedule -Override @{ id = 'sch-skip'; collisionPolicy = 'skip' }
        $skipper.nextRunUtc = '2026-05-04T08:00:00Z'
        $script:DeskPilot.Schedules.schedules = @($blocking, $skipper)
        $script:DeskPilot.TurnRunning = $true

        Update-DpScheduleState -Now ([datetime]::new(2026, 5, 4, 8, 0, 30, [DateTimeKind]::Utc))

        @($script:DeskPilot.Schedules.queue).Count | Should -Be 1
        $script:DeskPilot.Schedules.queue[0].scheduleId | Should -Be 'sch-block'
        ($script:DeskPilot.Schedules.schedules | Where-Object { $_.id -eq 'sch-skip' }).lastRun.outcome | Should -Be 'skipped'
    }

    It 'records a run missed by more than the catch-up window instead of running it late' {
        $schedule = New-DpTestSchedule -Override @{ id = 'sch-missed'; catchUpMinutes = 30 }
        $schedule.nextRunUtc = '2026-05-04T08:00:00Z'
        $script:DeskPilot.Schedules.schedules = @($schedule)

        Update-DpScheduleState -Now ([datetime]::new(2026, 5, 4, 12, 0, 0, [DateTimeKind]::Utc))

        @($script:DeskPilot.Schedules.queue).Count | Should -Be 0
        $script:DeskPilot.Schedules.schedules[0].lastRun.outcome | Should -Be 'missed'
        $script:DeskPilot.Schedules.schedules[0].nextRunUtc | Should -Be '2026-05-05T08:00:00Z'
    }

    It 'expires a queued run that waited longer than its expiry window' {
        $schedule = New-DpTestSchedule -Override @{ id = 'sch-expire'; expiryMinutes = 10 }
        $schedule.nextRunUtc = '2026-05-06T08:00:00Z'
        $script:DeskPilot.Schedules.schedules = @($schedule)
        $script:DeskPilot.Schedules.queue = @(@{ scheduleId = 'sch-expire'; dueUtc = '2026-05-04T08:00:00Z'; queuedUtc = '2026-05-04T08:00:00Z' })

        Update-DpScheduleState -Now ([datetime]::new(2026, 5, 4, 8, 30, 0, [DateTimeKind]::Utc))

        @($script:DeskPilot.Schedules.queue).Count | Should -Be 0
        $script:DeskPilot.Schedules.schedules[0].lastRun.outcome | Should -Be 'expired'
    }

    It 'bounds the queue' {
        $schedules = 1..25 | ForEach-Object {
            $s = New-DpTestSchedule -Override @{ id = "sch-$_" }
            $s.nextRunUtc = '2026-05-04T08:00:00Z'
            $s
        }
        $script:DeskPilot.Schedules.schedules = @($schedules)
        $script:DeskPilot.TurnRunning = $true

        Update-DpScheduleState -Now ([datetime]::new(2026, 5, 4, 8, 0, 30, [DateTimeKind]::Utc))

        @($script:DeskPilot.Schedules.queue).Count | Should -BeLessOrEqual 20
    }

    It 'runs a queued entry when the Engine is idle and a Turn is allowed' {
        $schedule = New-DpTestSchedule -Override @{ id = 'sch-run' }
        $schedule.nextRunUtc = '2026-05-06T08:00:00Z'
        $script:DeskPilot.Schedules.schedules = @($schedule)
        $script:DeskPilot.Schedules.queue = @(@{ scheduleId = 'sch-run'; dueUtc = '2026-05-04T08:00:00Z'; queuedUtc = '2026-05-04T08:00:00Z' })

        Update-DpScheduleState -AllowTurn -Now ([datetime]::new(2026, 5, 4, 8, 0, 5, [DateTimeKind]::Utc))

        Should -Invoke Invoke-DpScheduledTurn -Times 1 -Exactly
        @($script:DeskPilot.Schedules.queue).Count | Should -Be 0
        $script:DeskPilot.Schedules.schedules[0].lastRun.outcome | Should -Be 'completed'
        $script:DeskPilot.Schedules.claim | Should -BeNullOrEmpty
    }

    It 'never starts a run while a Turn holds the Engine' {
        $schedule = New-DpTestSchedule -Override @{ id = 'sch-busy' }
        $schedule.nextRunUtc = '2026-05-06T08:00:00Z'
        $script:DeskPilot.Schedules.schedules = @($schedule)
        $script:DeskPilot.Schedules.queue = @(@{ scheduleId = 'sch-busy'; dueUtc = '2026-05-04T08:00:00Z'; queuedUtc = '2026-05-04T08:00:00Z' })
        $script:DeskPilot.TurnRunning = $true

        Update-DpScheduleState -AllowTurn -Now ([datetime]::new(2026, 5, 4, 8, 0, 5, [DateTimeKind]::Utc))

        Should -Invoke Invoke-DpScheduledTurn -Times 0 -Exactly
        @($script:DeskPilot.Schedules.queue).Count | Should -Be 1
    }

    It 'never starts a run when the caller is not allowed to start a Turn' {
        $schedule = New-DpTestSchedule -Override @{ id = 'sch-noturn' }
        $schedule.nextRunUtc = '2026-05-06T08:00:00Z'
        $script:DeskPilot.Schedules.schedules = @($schedule)
        $script:DeskPilot.Schedules.queue = @(@{ scheduleId = 'sch-noturn'; dueUtc = '2026-05-04T08:00:00Z'; queuedUtc = '2026-05-04T08:00:00Z' })

        Update-DpScheduleState -Now ([datetime]::new(2026, 5, 4, 8, 0, 5, [DateTimeKind]::Utc))

        Should -Invoke Invoke-DpScheduledTurn -Times 0 -Exactly
        @($script:DeskPilot.Schedules.queue).Count | Should -Be 1
    }

    It 'reports an interrupted claim once and does not re-run it after a restart' {
        $schedule = New-DpTestSchedule -Override @{ id = 'sch-claim' }
        $schedule.nextRunUtc = '2026-05-06T08:00:00Z'
        $script:DeskPilot.Schedules.schedules = @($schedule)
        $script:DeskPilot.Schedules.claim = @{ scheduleId = 'sch-claim'; startedUtc = '2026-05-04T08:00:00Z' }

        Update-DpScheduleState -AllowTurn -Now ([datetime]::new(2026, 5, 4, 9, 0, 0, [DateTimeKind]::Utc))

        Should -Invoke Invoke-DpScheduledTurn -Times 0 -Exactly
        $script:DeskPilot.Schedules.claim | Should -BeNullOrEmpty
        $script:DeskPilot.Schedules.schedules[0].lastRun.outcome | Should -Be 'interrupted'
    }

    It 'records a failed run without losing the schedule' {
        Mock Invoke-DpScheduledTurn { @{ outcome = 'failed'; detail = 'Project no longer registered.'; conversationId = $null } }
        $schedule = New-DpTestSchedule -Override @{ id = 'sch-fail' }
        $schedule.nextRunUtc = '2026-05-06T08:00:00Z'
        $script:DeskPilot.Schedules.schedules = @($schedule)
        $script:DeskPilot.Schedules.queue = @(@{ scheduleId = 'sch-fail'; dueUtc = '2026-05-04T08:00:00Z'; queuedUtc = '2026-05-04T08:00:00Z' })

        Update-DpScheduleState -AllowTurn -Now ([datetime]::new(2026, 5, 4, 8, 0, 5, [DateTimeKind]::Utc))

        $script:DeskPilot.Schedules.schedules[0].lastRun.outcome | Should -Be 'failed'
        $script:DeskPilot.Schedules.schedules[0].lastRun.detail | Should -Be 'Project no longer registered.'
        @($script:DeskPilot.Schedules.schedules).Count | Should -Be 1
    }

    It 'bounds retained run history' {
        $schedule = New-DpTestSchedule -Override @{ id = 'sch-history' }
        $schedule.nextRunUtc = '2026-05-06T08:00:00Z'
        $script:DeskPilot.Schedules.schedules = @($schedule)

        1..25 | ForEach-Object {
            $script:DeskPilot.Schedules.queue = @(@{ scheduleId = 'sch-history'; dueUtc = '2026-05-04T08:00:00Z'; queuedUtc = '2026-05-04T08:00:00Z' })
            Update-DpScheduleState -AllowTurn -Now ([datetime]::new(2026, 5, 4, 8, 0, 5, [DateTimeKind]::Utc))
        }

        @($script:DeskPilot.Schedules.schedules[0].history).Count | Should -BeLessOrEqual 20
    }
}

Describe 'Invoke-DpScheduledTurn' -Tag 'Unit' {
    BeforeEach {
        $script:DeskPilot = @{
            DataDir               = (Join-Path $TestDrive ('run-' + [guid]::NewGuid().ToString('N')))
            TurnRunning           = $false
            Conversations         = @{}
            ConversationsRevision = 0
            Models                = @()
            Settings              = @{
                projects        = @(@{ id = 'p-a'; name = 'Alpha'; path = (Join-Path $TestDrive 'alpha') })
                workspaceFolder = $null
                agentsRoot      = $null
                model           = 'claude-opus-5'
                permissions     = @{ browsing = $true; file = $true; terminal = $true; askUser = $true; userTools = $true; mcp = $true }
            }
            Diagnostics           = @{ Log = (New-DpDiagnosticLog -MaxEntries 50 -MaxBytes 65536) }
        }
        Mock Invoke-DpTurn { }
        Mock Save-DpConversationStore { }
    }

    It 'fails visibly when the referenced Project is gone and never starts a Turn' {
        $schedule = New-DpTestSchedule -Override @{ id = 'sch-noproject'; projectId = 'p-missing' }

        $result = Invoke-DpScheduledTurn -Schedule $schedule

        $result.outcome | Should -Be 'failed'
        $result.detail | Should -Match 'Project'
        Should -Invoke Invoke-DpTurn -Times 0 -Exactly
    }

    It 'fails visibly when the referenced Model is no longer advertised' {
        $script:DeskPilot.Models = @(@{ id = 'claude-opus-5' })
        $schedule = New-DpTestSchedule -Override @{ id = 'sch-nomodel'; model = 'model-that-went-away' }

        $result = Invoke-DpScheduledTurn -Schedule $schedule

        $result.outcome | Should -Be 'failed'
        $result.detail | Should -Match 'Model'
        Should -Invoke Invoke-DpTurn -Times 0 -Exactly
    }

    It 'runs the Turn in its own Conversation and leaves it unread' {
        $schedule = New-DpTestSchedule -Override @{ id = 'sch-ok'; projectId = 'p-a' }

        $result = Invoke-DpScheduledTurn -Schedule $schedule

        $result.outcome | Should -Be 'completed'
        Should -Invoke Invoke-DpTurn -Times 1 -Exactly
        @($script:DeskPilot.Conversations.Values).Count | Should -Be 1
        $conversation = @($script:DeskPilot.Conversations.Values)[0]
        $conversation.unread | Should -BeTrue
        $conversation.titleLocked | Should -BeTrue
        $conversation.title | Should -Match 'Morning review'
        $script:DeskPilot.ConversationsRevision | Should -BeGreaterThan 0
    }

    It 'drops Terminal authority for an unattended run under the safe permission mode' {
        $schedule = New-DpTestSchedule -Override @{ id = 'sch-safe'; projectId = 'p-a'; permissionMode = 'safe' }

        $null = Invoke-DpScheduledTurn -Schedule $schedule

        Should -Invoke Invoke-DpTurn -Times 1 -Exactly -ParameterFilter {
            $Scope.permissions.terminal -eq $false -and $Scope.workspaceFolder -eq (Join-Path $TestDrive 'alpha')
        }
    }

    It 'keeps the live Permissions when the user opted the schedule into live mode' {
        $schedule = New-DpTestSchedule -Override @{ id = 'sch-live'; projectId = 'p-a'; permissionMode = 'live' }

        $null = Invoke-DpScheduledTurn -Schedule $schedule

        Should -Invoke Invoke-DpTurn -Times 1 -Exactly -ParameterFilter {
            -not $Scope.ContainsKey('permissions')
        }
    }

    It 'reports a Turn failure as a failed run rather than throwing' {
        Mock Invoke-DpTurn { throw 'engine exploded' }
        $schedule = New-DpTestSchedule -Override @{ id = 'sch-throw'; projectId = 'p-a' }

        $result = Invoke-DpScheduledTurn -Schedule $schedule

        $result.outcome | Should -Be 'failed'
        $result.detail | Should -Match 'engine exploded'
    }
}

Describe 'Get-DpSchedulePayload' -Tag 'Unit' {
    It 'reports schedules, queue depth and the running claim without leaking the whole prompt store' {
        $script:DeskPilot = @{
            Schedules         = @{
                schedules = @((ConvertTo-DpSchedule -InputObject @{
                            id         = 'sch-view'
                            name       = 'Daily'
                            prompt     = 'Do the thing.'
                            recurrence = 'daily'
                            timeOfDay  = '08:00'
                            timeZoneId = 'UTC'
                        }))
                queue     = @(@{ scheduleId = 'sch-view'; dueUtc = '2026-05-04T08:00:00Z'; queuedUtc = '2026-05-04T08:00:00Z' })
                claim     = $null
            }
            SchedulesRevision = 3
        }

        $payload = Get-DpSchedulePayload

        @($payload.schedules).Count | Should -Be 1
        $payload.schedules[0].id | Should -Be 'sch-view'
        $payload.schedules[0].prompt | Should -Be 'Do the thing.'
        $payload.queueDepth | Should -Be 1
        $payload.running | Should -BeNullOrEmpty
        $payload.revision | Should -Be 3
    }
}

Describe 'Schedule routes' -Tag 'Unit' {
    BeforeEach {
        $script:DeskPilot = @{
            DataDir           = (Join-Path $TestDrive ('route-' + [guid]::NewGuid().ToString('N')))
            TurnRunning       = $false
            Schedules         = @{ schedules = @(); queue = @(); claim = $null }
            SchedulesRevision = 0
            Settings          = @{ projects = @() }
            Diagnostics       = @{ Log = (New-DpDiagnosticLog -MaxEntries 50 -MaxBytes 65536) }
        }
        $script:responseStream = [System.IO.MemoryStream]::new()
        Mock Save-DpScheduleStore { }
    }

    AfterEach {
        $script:responseStream.Dispose()
        $script:DeskPilot = $null
    }

    It 'creates a schedule and computes its next run' {
        $body = [pscustomobject]@{
            name       = 'Weekday review'
            prompt     = 'Summarise the overnight reports.'
            recurrence = 'weekly'
            timeOfDay  = '08:00'
            weekdays   = @(1, 2, 3, 4, 5)
            timeZoneId = 'UTC'
        }
        Invoke-DpRouteHandler -Name 'createSchedule' -Body $body -Stream $script:responseStream

        $result = Get-DpRouteJson -Stream $script:responseStream
        $result.Status | Should -Match '201'
        @($result.Json.schedules).Count | Should -Be 1
        $result.Json.schedules[0].nextRunUtc | Should -Not -BeNullOrEmpty
    }

    It 'refuses an invalid schedule with a 400 rather than storing it' {
        $body = [pscustomobject]@{ name = 'Broken'; prompt = 'x'; recurrence = 'daily'; timeOfDay = 'noon' }
        Invoke-DpRouteHandler -Name 'createSchedule' -Body $body -Stream $script:responseStream

        $result = Get-DpRouteJson -Stream $script:responseStream
        $result.Status | Should -Match '400'
        $result.Json.error.code | Should -Be 'bad_schedule'
        @($script:DeskPilot.Schedules.schedules).Count | Should -Be 0
    }

    It 'ignores an id supplied on create so a crafted body cannot overwrite a schedule' {
        $script:DeskPilot.Schedules.schedules = @((New-DpTestSchedule -Override @{ id = 'sch-existing' }))
        $body = [pscustomobject]@{ id = 'sch-existing'; name = 'Impostor'; prompt = 'x'; recurrence = 'daily'; timeOfDay = '09:00'; timeZoneId = 'UTC' }
        Invoke-DpRouteHandler -Name 'createSchedule' -Body $body -Stream $script:responseStream

        @($script:DeskPilot.Schedules.schedules).Count | Should -Be 2
        @($script:DeskPilot.Schedules.schedules | Where-Object { $_.id -eq 'sch-existing' }).Count | Should -Be 1
    }

    It 'updates a schedule in place and keeps its run history' {
        $existing = New-DpTestSchedule -Override @{ id = 'sch-edit' }
        $existing.history = @(@{ outcome = 'completed'; detail = 'ok'; atUtc = '2026-05-04T08:00:00Z'; conversationId = 'c-1' })
        $script:DeskPilot.Schedules.schedules = @($existing)
        $body = [pscustomobject]@{ id = 'other'; name = 'Renamed'; prompt = 'New prompt.'; recurrence = 'daily'; timeOfDay = '09:30'; timeZoneId = 'UTC' }

        Invoke-DpRouteHandler -Name 'updateSchedule' -RouteParams @{ id = 'sch-edit' } -Body $body -Stream $script:responseStream

        $result = Get-DpRouteJson -Stream $script:responseStream
        $result.Status | Should -Match '200'
        @($script:DeskPilot.Schedules.schedules).Count | Should -Be 1
        $script:DeskPilot.Schedules.schedules[0].id | Should -Be 'sch-edit'
        $script:DeskPilot.Schedules.schedules[0].name | Should -Be 'Renamed'
        @($script:DeskPilot.Schedules.schedules[0].history).Count | Should -Be 1
    }

    It 'answers 404 for an update to a schedule that does not exist' {
        $body = [pscustomobject]@{ name = 'Ghost'; prompt = 'x'; recurrence = 'daily'; timeOfDay = '09:30'; timeZoneId = 'UTC' }
        Invoke-DpRouteHandler -Name 'updateSchedule' -RouteParams @{ id = 'sch-gone' } -Body $body -Stream $script:responseStream

        (Get-DpRouteJson -Stream $script:responseStream).Status | Should -Match '404'
    }

    It 'deletes a schedule and drops the run it had waiting' {
        $script:DeskPilot.Schedules.schedules = @((New-DpTestSchedule -Override @{ id = 'sch-del' }))
        $script:DeskPilot.Schedules.queue = @(@{ scheduleId = 'sch-del'; dueUtc = '2026-05-04T08:00:00Z'; queuedUtc = '2026-05-04T08:00:00Z' })

        Invoke-DpRouteHandler -Name 'deleteSchedule' -RouteParams @{ id = 'sch-del' } -Stream $script:responseStream

        (Get-DpRouteJson -Stream $script:responseStream).Status | Should -Match '200'
        @($script:DeskPilot.Schedules.schedules).Count | Should -Be 0
        @($script:DeskPilot.Schedules.queue).Count | Should -Be 0
    }

    It 'queues a manual run instead of starting one on the accept thread' {
        Mock Invoke-DpScheduledTurn { @{ outcome = 'completed'; detail = 'ok'; conversationId = 'c-1' } }
        $script:DeskPilot.Schedules.schedules = @((New-DpTestSchedule -Override @{ id = 'sch-now' }))

        Invoke-DpRouteHandler -Name 'runSchedule' -RouteParams @{ id = 'sch-now' } -Stream $script:responseStream

        (Get-DpRouteJson -Stream $script:responseStream).Status | Should -Match '202'
        @($script:DeskPilot.Schedules.queue).Count | Should -Be 1
        $script:DeskPilot.Schedules.queue[0].source | Should -Be 'manual'
        Should -Invoke Invoke-DpScheduledTurn -Times 0 -Exactly
    }

    It 'refuses a second manual run while one is already waiting' {
        $script:DeskPilot.Schedules.schedules = @((New-DpTestSchedule -Override @{ id = 'sch-twice' }))
        $script:DeskPilot.Schedules.queue = @(@{ scheduleId = 'sch-twice'; dueUtc = '2026-05-04T08:00:00Z'; queuedUtc = [datetime]::UtcNow.ToString('o') })

        Invoke-DpRouteHandler -Name 'runSchedule' -RouteParams @{ id = 'sch-twice' } -Stream $script:responseStream

        $result = Get-DpRouteJson -Stream $script:responseStream
        $result.Status | Should -Match '409'
        $result.Json.error.code | Should -Be 'already_queued'
    }
}

