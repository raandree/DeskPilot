BeforeAll {
    Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '../../source/Private') -Filter '*.ps1' |
        ForEach-Object { . $_.FullName }
}

Describe 'Child Host Server admission' {
    BeforeEach {
        $script:priorState = $script:DeskPilot
        $settings = Get-DpDefaultSettings
        $settings.workspaceFolder = Join-Path $TestDrive 'project'
        $settings.selectedProjectId = 'project'
        $settings.model = 'claude-haiku-4.5'
        $settings.permissions.file = $true
        $settings.permissions.terminal = $true
        $settings.childExecution = ConvertTo-DpChildExecution -InputObject @{
            enabled = $true; profile = 'single-child-v3'; budgetMode = 'provider-estimate'
        }
        $script:DeskPilot = @{
            Settings = $settings; TurnRunning = $false; CancelRequested = $false
            Token = 'launch'; DataDir = $TestDrive; Engine = @{ ModulePath = 'fixture'; TokenPath = 'private-token-path' }
            Child = @{ Controller = $null; Runtime = @{}; Proof = @{}; Health = @{}; CleanupBlocked = $false; Last = $null }
            Conversations = @{ conversation = @{ id = 'conversation'; model = $null; messages = [System.Collections.Generic.List[object]]::new(); history = @() } }
        }
        $script:started = $null
        Mock Get-DpChildReadiness { @{ ready = $true; enabled = $true; profile = 'single-child-v3'; budgetMode = 'provider-estimate' } }
        Mock Get-DpChildRuntimeHealth { @{ ready = $true; cleanupClear = $true; checkedUtc = [datetime]::UtcNow.ToString('o') } }
        Mock Save-DpConversationStore {}
    }

    AfterEach { $script:DeskPilot = $script:priorState }

    It 'acquires active Turn admission before any child capture or process creation' {
        (Get-Command Start-DpChildRun -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        Mock New-DpChildRunController {
            $script:DeskPilot.TurnRunning | Should -BeTrue
            $script:started = $Request
            [pscustomobject]@{ Id = 'child-id' }
        }
        $result = Start-DpChildRun -Conversation $script:DeskPilot.Conversations.conversation -Body @{
            consent = $true; prompt = 'Inspect input.'; selectedPaths = @('input.txt')
            profile = 'single-child-v3'; budgetMode = 'provider-estimate'; projectAccess = 'read-only'
        }
        $result.id | Should -BeExactly 'child-id'
        $script:DeskPilot.Conversations.conversation.messages.Count | Should -Be 1
        $script:DeskPilot.Conversations.conversation.messages[0].childRunId | Should -BeExactly 'child-id'
        $script:DeskPilot.Conversations.conversation.messages[0].text | Should -BeExactly 'Inspect input.'
        $script:started.selectedPaths | Should -Be @('input.txt')
        $script:started.launchId | Should -Not -BeExactly $script:DeskPilot.Token
        $script:started.ContainsKey('history') | Should -BeFalse
        $script:started.ContainsKey('agentMemory') | Should -BeFalse
        @($script:started.permissions.Keys | Sort-Object) | Should -Be @('file', 'terminal') -Because 'only owned child capability categories are passed'
        $script:DeskPilot.TurnRunning | Should -BeTrue
        Should -Invoke Get-DpChildRuntimeHealth -Times 1 -Exactly
    }

    It 'refuses admission while explicit runtime preparation is still running' {
        $script:DeskPilot.Child.SetupJob = [pscustomobject]@{ State = 'Running' }
        Mock New-DpChildRunController { throw 'Must not create a child during preparation.' }
        { Start-DpChildRun -Conversation $script:DeskPilot.Conversations.conversation -Body @{
            consent = $true; prompt = 'Inspect input.'; selectedPaths = @('input.txt')
            profile = 'single-child-v3'; budgetMode = 'provider-estimate'; projectAccess = 'read-only'
        } } | Should -Throw -ExpectedMessage '*preparation*'
        Should -Invoke New-DpChildRunController -Times 0 -Exactly
    }

    It 'refuses <Case> before child creation' -ForEach @(
        @{ Case = 'missing consent'; Patch = @{ consent = $false } }
        @{ Case = 'provider estimates not explicit'; Patch = @{ budgetMode = 'verified' } }
        @{ Case = 'unsupported scope'; Patch = @{ tools = @('browser') } }
        @{ Case = 'empty selection'; Patch = @{ selectedPaths = @() } }
    ) {
        (Get-Command Start-DpChildRun -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        Mock New-DpChildRunController { throw 'Should not create a child.' }
        $body = @{ consent = $true; prompt = 'Inspect input.'; selectedPaths = @('input.txt'); profile = 'single-child-v3'; budgetMode = 'provider-estimate'; projectAccess = 'read-only' }
        foreach ($key in $Patch.Keys) { $body[$key] = $Patch[$key] }
        { Start-DpChildRun -Conversation $script:DeskPilot.Conversations.conversation -Body $body } | Should -Throw
        Should -Invoke New-DpChildRunController -Times 0 -Exactly
        $script:DeskPilot.TurnRunning | Should -BeFalse
    }

    It 'refuses a selected Model mismatch without silently changing it' {
        (Get-Command Start-DpChildRun -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        Mock New-DpChildRunController { throw 'Should not create a child.' }
        $script:DeskPilot.Conversations.conversation.model = 'gpt-5-mini'
        { Start-DpChildRun -Conversation $script:DeskPilot.Conversations.conversation -Body @{
            consent = $true; prompt = 'Inspect input.'; selectedPaths = @('input.txt')
            profile = 'single-child-v3'; budgetMode = 'provider-estimate'; projectAccess = 'read-only'
        } } | Should -Throw -ExpectedMessage '*Model*'
        $script:DeskPilot.Conversations.conversation.model | Should -BeExactly 'gpt-5-mini'
        Should -Invoke New-DpChildRunController -Times 0 -Exactly
    }
}
