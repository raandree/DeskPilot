BeforeAll {
    Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '../../source/Private') -Filter '*.ps1' |
        ForEach-Object { . $_.FullName }
}

Describe 'Child Host Server state' {
    BeforeEach {
        $script:priorState = $script:DeskPilot
        $script:snapshot = @{
            id = 'child-id'; conversationId = 'conversation'; parentTurnId = 'parent-turn'
            status = 'completed'; cleanupSucceeded = $true; content = '<img src="https://untrusted.example">'
            profile = 'single-child-v3'; budgetMode = 'provider-estimate'; model = 'claude-haiku-4.5'
            code = ''; events = @(); filesRead = @('input.txt'); filesWritten = @(); commandsRun = @()
            usage = @{ UsageKnown = $false; CostUSD = $null; PromptTokens = $null; CompletionTokens = $null; TotalTokens = $null; Credits = $null; ReservedTokens = 132; ReservedCostUSD = 0.001; KnownUsage = @{ PromptTokens = 10; CompletionTokens = 2; TotalTokens = 12; CostUSD = 0.0001; Credits = 0.01 } }
        }
        $controller = [pscustomobject]@{ Completion = [Threading.Tasks.Task]::CompletedTask; Id = 'child-id'; ConversationId = 'conversation' }
        $controller | Add-Member -MemberType ScriptMethod -Name Snapshot -Value { $script:snapshot | ConvertTo-Json -Depth 12 -Compress }
        $controller | Add-Member -MemberType ScriptMethod -Name UpdatePermissions -Value { param($File, $Terminal, $Enabled) }
        $controller | Add-Member -MemberType ScriptMethod -Name Dispose -Value {}
        $settings = Get-DpDefaultSettings
        $settings.childExecution.enabled = $true
        $script:DeskPilot = @{
            Settings = $settings; TurnRunning = $true; DataDir = $TestDrive; CancelRequested = $false
            Conversations = @{ conversation = @{ id = 'conversation'; messages = [System.Collections.Generic.List[object]]::new(); history = @(@{ role = 'user'; content = 'parent-only-history' }) } }
            Child = @{ Controller = $controller; Recorded = $false; Last = $null; Prompt = 'Selected child task.'; CleanupBlocked = $false; SetupJob = $null }
        }
        Mock Save-DpConversationStore {}
        Mock Update-DpUsage {}
    }

    AfterEach { $script:DeskPilot = $script:priorState }

    It 'records one child result without adding child prose to parent history or active content' {
        (Get-Command Update-DpChildRunState -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        Update-DpChildRunState
        Update-DpChildRunState
        $script:DeskPilot.TurnRunning | Should -BeFalse
        $messages = @($script:DeskPilot.Conversations.conversation.messages)
        $messages.Count | Should -Be 2
        $messages[0].text | Should -BeExactly 'Selected child task.'
        $messages[1].text | Should -BeExactly 'Private child run: completed.'
        $messages[1].text | Should -Not -Match 'untrusted.example|img'
        $messages[1].childRunId | Should -BeExactly 'child-id'
        $messages[1].usage.usageKnown | Should -BeFalse
        $messages[1].usage.costUSD | Should -BeNullOrEmpty
        $messages[1].usage.reservedTokens | Should -Be 132
        $script:DeskPilot.Conversations.conversation.history[0].content | Should -BeExactly 'parent-only-history'
        @($script:DeskPilot.Conversations.conversation.history).Count | Should -Be 1
        Should -Invoke Update-DpUsage -Times 1 -Exactly -ParameterFilter { -not $Usage.priced -and $Usage.costUSD -eq 0.0001 }
    }

    It 'retains the execution gate and cleanup failure until explicit reconciliation' {
        (Get-Command Update-DpChildRunState -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        $script:snapshot.status = 'cleanup-failed'
        $script:snapshot.cleanupSucceeded = $false
        Update-DpChildRunState
        $script:DeskPilot.Child.CleanupBlocked | Should -BeTrue
        $script:DeskPilot.TurnRunning | Should -BeTrue
    }

    It 'does not duplicate the task recorded at child admission' {
        $script:DeskPilot.Conversations.conversation.messages.Add(@{ id = 'parent-turn'; role = 'user'; text = 'Selected child task.'; childRunId = 'child-id' })
        Update-DpChildRunState
        $script:DeskPilot.Conversations.conversation.messages.Count | Should -Be 2
    }
}
