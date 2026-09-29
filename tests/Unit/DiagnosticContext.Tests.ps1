#requires -Version 7.0

BeforeAll {
    $privateRoot = Join-Path $PSScriptRoot '..' '..' 'source' 'Private'
    Get-ChildItem -LiteralPath $privateRoot -Filter '*.ps1' | ForEach-Object { . $_.FullName }
}

Describe 'Content-free Diagnostic context' -Tag 'Unit' {
    BeforeEach {
        $script:DeskPilot = @{}
        $log = New-DpDiagnosticLog -MaxEntries 10 -MaxBytes 8192
        $parameters = @{
            Log = $log
            Severity = 'information'
            Component = 'turn'
            EventId = 'turn.completed'
            Summary = 'Turn completed.'
        }
    }

    It 'accepts structured correlation separately from the human-readable summary' {
        (Get-Command Add-DpDiagnosticLog).Parameters.ContainsKey('Context') | Should -BeTrue
        Add-DpDiagnosticLog @parameters -Context @{
            conversationId = 'c_0123456789'
            turnId = 'm_abcdef0123'
            toolSequence = 2
            action = 'read'
            outcome = 'completed'
            durationMs = 125
        }

        $entry = @(Get-DpDiagnosticLog -Log $log)[0]
        $entry.context.conversationId | Should -BeExactly 'c_0123456789'
        $entry.context.turnId | Should -BeExactly 'm_abcdef0123'
        $entry.context.toolSequence | Should -Be 2
        $entry.context.durationMs | Should -Be 125
        $entry.context.outcome | Should -BeExactly 'completed'
    }

    It 'never serializes arbitrary arguments, prompts, paths, or nested objects' {
        (Get-Command Add-DpDiagnosticLog).Parameters.ContainsKey('Context') | Should -BeTrue
        Add-DpDiagnosticLog @parameters -Context @{
            turnId = 'm_abcdef0123'
            prompt = 'PRIVATE-PROMPT'
            arguments = @{ content = 'PRIVATE-CONTENT' }
            path = 'PRIVATE-PATH'
            authorization = 'PRIVATE-CREDENTIAL'
            model = 'PRIVATE-MODEL-NAME'
        }

        $entry = @(Get-DpDiagnosticLog -Log $log)[0]
        @($entry.context.Keys) | Should -Be @('turnId')
        ($entry | ConvertTo-Json -Depth 6) | Should -Not -Match 'PRIVATE-'
    }

    It 'preserves unknown Usage as null and distinguishes estimates from measurements' {
        (Get-Command Add-DpDiagnosticLog).Parameters.ContainsKey('Context') | Should -BeTrue
        Add-DpDiagnosticLog @parameters -Context @{
            promptTokens = 25
            completionTokens = $null
            totalTokens = $null
            costUSD = $null
            estimated = $true
            partial = $true
        }

        $context = @(Get-DpDiagnosticLog -Log $log)[0].context
        $context.promptTokens | Should -Be 25
        $context.completionTokens | Should -BeNullOrEmpty
        $context.Contains('costUSD') | Should -BeTrue
        $context.costUSD | Should -BeNullOrEmpty
        $context.estimated | Should -BeTrue
        $context.partial | Should -BeTrue
        ($context | ConvertTo-Json -Compress) | Should -Match '"costUSD":null'
    }

    It 'copies the allowed scalars rather than retaining the mutable caller object' {
        (Get-Command Add-DpDiagnosticLog).Parameters.ContainsKey('Context') | Should -BeTrue
        $context = @{ turnId = 'm_abcdef0123'; toolSequence = 1 }
        Add-DpDiagnosticLog @parameters -Context $context
        $context.turnId = 'm_0000000000'
        $context.toolSequence = 50
        @(Get-DpDiagnosticLog -Log $log)[0].context.toolSequence | Should -Be 1
        @(Get-DpDiagnosticLog -Log $log)[0].context.turnId | Should -BeExactly 'm_abcdef0123'
    }

    It 'leaves the legacy log shape unchanged without structured context' {
        Add-DpDiagnosticLog @parameters
        $entry = @(Get-DpDiagnosticLog -Log $log)[0]
        $entry.Contains('context') | Should -BeFalse
    }

    It 'accounts for structured UTF-8 bytes in the existing retention bound' {
        (Get-Command Add-DpDiagnosticLog).Parameters.ContainsKey('Context') | Should -BeTrue
        $parameters.Log = New-DpDiagnosticLog -MaxEntries 10 -MaxBytes 650
        foreach ($sequence in 1..5) {
            Add-DpDiagnosticLog @parameters -Context @{
                turnId = 'm_abcdef0123'
                toolSequence = $sequence
                outcome = 'completed'
                costUSD = 0.0125
            }
        }
        $entries = @(Get-DpDiagnosticLog -Log $parameters.Log)
        $entries.Count | Should -BeGreaterThan 0
        $entries.Count | Should -BeLessThan 5
        $parameters.Log.CurrentBytes | Should -BeLessOrEqual 650
        foreach ($entry in $entries) {
            [System.Text.Encoding]::UTF8.GetByteCount(($entry | ConvertTo-Json -Compress)) | Should -Be $entry.bytes
        }
    }

    It 'rejects invalid <Key> before appending an entry' -ForEach @(
        @{ Key = 'turnId'; Value = 'PRIVATE-IDENTIFIER' }
        @{ Key = 'conversationId'; Value = 'c_0123456789-extra' }
        @{ Key = 'toolSequence'; Value = -1 }
        @{ Key = 'durationMs'; Value = -1 }
        @{ Key = 'promptTokens'; Value = 1.5 }
        @{ Key = 'completionTokens'; Value = 'secret' }
        @{ Key = 'costUSD'; Value = [double]::NaN }
        @{ Key = 'costUSD'; Value = [double]::PositiveInfinity }
        @{ Key = 'costUSD'; Value = -0.1 }
        @{ Key = 'estimated'; Value = 'false' }
        @{ Key = 'outcome'; Value = 'PRIVATE-OUTCOME' }
        @{ Key = 'action'; Value = 'PRIVATE-ACTION' }
    ) {
        (Get-Command Add-DpDiagnosticLog).Parameters.ContainsKey('Context') | Should -BeTrue
        $context = @{ $Key = $Value }
        { Add-DpDiagnosticLog @parameters -Context $context } | Should -Throw -ExpectedMessage '*Diagnostic context*'
        @(Get-DpDiagnosticLog -Log $log) | Should -HaveCount 0
        $log.NextSequence | Should -Be 0
    }
}
