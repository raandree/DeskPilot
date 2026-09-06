#requires -Version 7.4

BeforeAll {
    $privateRoot = Join-Path $PSScriptRoot '..' '..' 'source' 'Private'
    Get-ChildItem -LiteralPath $privateRoot -Filter '*.ps1' | ForEach-Object { . $_.FullName }
}

Describe 'Child Agent execution policy' -Tag 'Unit' {
    It 'defaults to disabled private read-only execution without changing ordinary Turns' {
        $settings = Get-DpDefaultSettings

        $settings.ContainsKey('childExecution') | Should -BeTrue
        $settings.childExecution.enabled | Should -BeFalse
        $settings.childExecution.projectAccess | Should -BeExactly 'read-only'
        $settings.childExecution.network | Should -BeExactly 'off'
        $settings.childExecution.maxChildren | Should -Be 1
        $settings.childExecution.maxRetries | Should -Be 0
        $settings.childExecution.storageBytes | Should -Be 134217728
        $settings.childExecution.toolStorageBytes | Should -Be 100663296
        $settings.childExecution.inodeLimit | Should -Be 4096
        $settings.childExecution.durationSeconds | Should -Be 300
        $settings.childExecution.costUSD | Should -Be 0.25
        $settings.terminalExecution.mode | Should -BeExactly 'local'
        $settings.permissions.terminal | Should -BeFalse
        $settings.responseRetryCount | Should -Be 2

        $settings.childExecution.enabled = $true
        (Get-DpDefaultSettings).childExecution.enabled | Should -BeFalse
    }

    It 'merges a separately granted writable profile without mutating current Settings' {
        $current = Get-DpDefaultSettings
        $updated = Merge-DpSettings -Current $current -Patch @{
            childExecution = @{ enabled = $true; projectAccess = 'read-write'; durationSeconds = 120 }
        }

        $updated.childExecution.enabled | Should -BeTrue
        $updated.childExecution.projectAccess | Should -BeExactly 'read-write'
        $updated.childExecution.durationSeconds | Should -Be 120
        $updated.childExecution.baselineBytes | Should -Be 33554432
        $updated.childExecution.baselineFiles | Should -Be 2000
        $updated.childExecution.proposalBytes | Should -Be 25165824
        $updated.childExecution.proposalFiles | Should -Be 200
        $updated.childExecution.retentionBytes | Should -Be 536870912
        $updated.childExecution.retentionHours | Should -Be 24
        $updated.childExecution.approvalSeconds | Should -Be 60
        $updated.childExecution.leaseSeconds | Should -Be 15
        $updated.childExecution.cleanupSeconds | Should -Be 5
        $updated.childExecution.memoryBytes | Should -Be 1073741824
        $updated.childExecution.cpuCount | Should -Be 1
        $updated.childExecution.processLimit | Should -Be 64
        $updated.childExecution.inputTokens | Should -Be 16384
        $updated.childExecution.totalTokens | Should -Be 32768
        $updated.childExecution.outputTokens | Should -Be 4096
        $updated.childExecution.iterations | Should -Be 8
        $updated.childExecution.outputBytes | Should -Be 1048576
        $updated.childExecution.resultBytes | Should -Be 262144
        $updated.childExecution.eventBytes | Should -Be 16384
        $updated.childExecution.eventLimit | Should -Be 300
        $current.childExecution.enabled | Should -BeFalse
        $current.childExecution.projectAccess | Should -BeExactly 'read-only'
        $current.childExecution.durationSeconds | Should -Be 300
    }

    It 'rejects unsafe child policy <Field>' -ForEach @(
        @{ Field = 'enabled'; Value = 'true' }
        @{ Field = 'projectAccess'; Value = 'host' }
        @{ Field = 'network'; Value = 'allow-list' }
        @{ Field = 'maxChildren'; Value = 2 }
        @{ Field = 'maxRetries'; Value = 1 }
        @{ Field = 'storageBytes'; Value = 268435457 }
        @{ Field = 'toolStorageBytes'; Value = 201326593 }
        @{ Field = 'inodeLimit'; Value = 8193 }
        @{ Field = 'durationSeconds'; Value = 601 }
        @{ Field = 'costUSD'; Value = [double]::NaN }
        @{ Field = 'costUSD'; Value = 1.01 }
        @{ Field = 'baselineFiles'; Value = 1.5 }
        @{ Field = 'baselineBytes'; Value = '1024' }
        @{ Field = 'inputTokens'; Value = 32769 }
        @{ Field = 'totalTokens'; Value = 65537 }
        @{ Field = 'outputTokens'; Value = 8193 }
        @{ Field = 'retentionHours'; Value = 169 }
        @{ Field = 'retentionBytes'; Value = 1073741825 }
        @{ Field = 'privileged'; Value = $true }
        @{ Field = 'environment'; Value = @{} }
        @{ Field = 'skillRoots'; Value = @('C:/Users') }
    ) {
        { Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch @{
                childExecution = @{ $Field = $Value }
            } } | Should -Throw -ExpectedMessage "*childExecution*$Field*"
    }

    It 'refuses impossible storage partitions and does not reset corrupt persisted policy' {
        { Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch @{
                childExecution = @{ storageBytes = 67108864 }
            } } | Should -Throw -ExpectedMessage '*childExecution*storage*'

        $current = Get-DpDefaultSettings
        $current.childExecution.maxChildren = 2
        { Merge-DpSettings -Current $current -Patch @{ model = 'unchanged' } } |
            Should -Throw -ExpectedMessage '*childExecution*maxChildren*'
    }
}

Describe 'Child Agent Host Server readiness gate' -Tag 'Unit' {
    It 'reports incomplete profile contracts without calling the Engine or changing Settings' {
        $settings = Get-DpDefaultSettings
        $settings.childExecution.enabled = $true
        $before = $settings | ConvertTo-Json -Depth 12 -Compress
        Mock Invoke-DpDockerControl { throw 'Readiness must not mutate or probe the runtime.' }

        $readiness = Get-DpChildReadiness -Settings $settings

        $readiness.enabled | Should -BeTrue
        $readiness.ready | Should -BeFalse
        $readiness.state | Should -BeExactly 'blocked'
        @($readiness.missingContracts) | Should -Contain 'engine-request-admission'
        @($readiness.missingContracts) | Should -Contain 'child-engine-process'
        @($readiness.missingContracts) | Should -Contain 'child-approval-bridge'
        ($settings | ConvertTo-Json -Depth 12 -Compress) | Should -BeExactly $before
        Should -Invoke Invoke-DpDockerControl -Times 0 -Exactly
    }

    It 'refuses child startup with <Status> and runs no container or ordinary Turn' -ForEach @(
        @{ Enabled = $false; Busy = $false; Status = 403; Code = 'child_profile_disabled' }
        @{ Enabled = $true; Busy = $false; Status = 503; Code = 'child_profile_unavailable' }
        @{ Enabled = $true; Busy = $true; Status = 409; Code = 'busy' }
    ) {
        $prior = $script:DeskPilot
        $settings = Get-DpDefaultSettings
        $settings.childExecution.enabled = $Enabled
        $script:DeskPilot = @{ Settings = $settings; TurnRunning = $Busy; ChildRuntime = @{ ready = $true } }
        $stream = [IO.MemoryStream]::new()
        Mock New-DpChildToolContainer { throw 'An incomplete profile must not create a container.' }
        Mock Invoke-DpTurn { throw 'Child refusal must never fall back to an ordinary Turn.' }
        try {
            Invoke-DpRouteHandler -Name 'startChildRun' -RouteParams @{ id = 'conversation' } -Body @{} -Stream $stream
            $response = [Text.Encoding]::UTF8.GetString($stream.ToArray())
            $response | Should -Match "^HTTP/1.1 $Status"
            $response | Should -Match $Code
            $script:DeskPilot.TurnRunning | Should -Be $Busy
            Should -Invoke New-DpChildToolContainer -Times 0 -Exactly
            Should -Invoke Invoke-DpTurn -Times 0 -Exactly
        }
        finally { $stream.Dispose(); $script:DeskPilot = $prior }
    }
}