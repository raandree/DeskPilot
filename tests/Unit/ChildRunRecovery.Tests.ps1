BeforeAll {
    Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '../../source/Private') -Filter '*.ps1' |
        ForEach-Object { . $_.FullName }
}

Describe 'Complete child recovery' {
    BeforeEach {
        $script:directory = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:runId = 'a' * 32
        $script:runDirectory = Join-Path $script:directory ('child-runs/' + $script:runId)
        $null = New-Item -Path $script:runDirectory -ItemType Directory -Force
        $script:identity = @{
            schemaVersion = 1; runId = $script:runId; name = ('deskpilot-child-' + ('b' * 32))
            containerId = ''; state = 'starting'; cleanupSucceeded = $false
            retainedBytes = 33554432; expiresUtc = [datetime]::UtcNow.AddHours(1).ToString('o')
        }
        $script:identity | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:runDirectory 'ownership.json')
        $script:identity | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:runDirectory 'claim.json')
        $script:engineName = 'deskpilot-child-engine-' + $script:runId
        $script:engineId = 'c' * 64
        $script:engineRecord = @{
            schemaVersion = 1; runId = $script:runId; name = $script:engineName; image = ('sha256:' + ('d' * 64))
            containerId = ''; state = 'starting'; cleanupSucceeded = $false
        }
        $script:engineRecord | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:runDirectory 'engine-ownership.json')
        $script:engineRecord.containerId = $script:engineId
        $script:engineRecord.state = 'running'
        $script:engineRecord | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:runDirectory 'engine.json')
        $script:engineRemoved = $false
        Mock Invoke-DpDockerControl {
            if ($Argument[0] -eq 'ps') {
                if (-not $script:engineRemoved -and ($Argument -contains ('name=^/' + $script:engineName + '$'))) { return $script:engineId }
                return ''
            }
            if ($Argument[0] -eq 'inspect') {
                return ConvertTo-Json -Depth 8 -Compress -InputObject @(@{
                    Id = $script:engineId; Name = ('/' + $script:engineName); Image = $script:engineRecord.image
                    Config = @{ Labels = @{ 'io.deskpilot.child' = '1'; 'io.deskpilot.child.run' = $script:runId; 'io.deskpilot.child.component' = 'engine' } }
                })
            }
            if ($Argument[0] -eq 'rm') { $script:engineRemoved = $true; return '' }
            throw 'Unexpected recovery operation.'
        }
    }

    It 'removes the separately owned Engine and marks interrupted data without replay' {
        @{ id = $script:runId; conversationId = 'conversation'; status = 'running'; usage = @{ UsageKnown = $false; ReservedTokens = 132 }; cleanupSucceeded = $false } |
            ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $script:runDirectory 'run.json')
        $result = Remove-DpChildRun -DataDirectory $script:directory -Confirm:$false
        $script:engineRemoved | Should -BeTrue
        $result.containersRemoved | Should -Be 1
        $result.interrupted | Should -Be 1
        $claim = Get-Content -LiteralPath (Join-Path $script:runDirectory 'claim.json') -Raw | ConvertFrom-Json
        $claim.cleanupSucceeded | Should -BeTrue
        $claim.outcome | Should -BeExactly 'interrupted'
        $record = Get-Content -LiteralPath (Join-Path $script:runDirectory 'run.json') -Raw | ConvertFrom-Json
        $record.status | Should -BeExactly 'failed'
        $record.code | Should -BeExactly 'interrupted'
        $record.cleanupSucceeded | Should -BeTrue
        $record.usage.UsageKnown | Should -BeFalse
        $record.usage.ReservedTokens | Should -Be 132
    }

    It 'refuses a changed Engine identity without removing the mismatched resource' {
        $script:engineRecord.containerId = 'e' * 64
        $script:engineRecord | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:runDirectory 'engine.json')
        { Remove-DpChildRun -DataDirectory $script:directory -Confirm:$false } | Should -Throw
        $script:engineRemoved | Should -BeFalse
    }

    It 'refuses a live exact provider process rather than treating its PID as an orphan' {
        @{
            schemaVersion = 1; runId = $script:runId; processId = $PID
            startTimeUtcTicks = [Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().Ticks
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:runDirectory 'provider.json')
        { Remove-DpChildRun -DataDirectory $script:directory -Confirm:$false } | Should -Throw -ExpectedMessage '*provider*'
        $script:engineRemoved | Should -BeFalse
    }

    It 'expires only completed owned records when age retention is explicitly requested' {
        $script:identity.state = 'stopped'
        $script:identity.cleanupSucceeded = $true
        $script:identity.expiresUtc = [datetime]::UtcNow.AddHours(-1).ToString('o')
        $script:identity | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:runDirectory 'claim.json')
        $script:engineRemoved = $true
        $result = Remove-DpChildRun -DataDirectory $script:directory -ExpireCompleted -Confirm:$false
        $result.removed | Should -Be 1
        Test-Path -LiteralPath $script:runDirectory | Should -BeFalse
    }
}
