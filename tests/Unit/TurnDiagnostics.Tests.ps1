#requires -Version 7.0

BeforeAll {
    $privateRoot = Join-Path $PSScriptRoot '..' '..' 'source' 'Private'
    Get-ChildItem -LiteralPath $privateRoot -Filter '*.ps1' | ForEach-Object { . $_.FullName }
}

Describe 'Content-free Turn lifecycle Diagnostics' -Tag 'Unit' {
    BeforeEach {
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.Open()
        $setup = [powershell]::Create()
        $setup.Runspace = $runspace
        $null = $setup.AddScript(@'
function global:Invoke-Shp {
    [CmdletBinding()]
    param($Prompt, $History, $SystemPrompt, $Model, $MaxToolIterations, [switch]$DisableTerminal)
    if ($global:TurnFixtureMode -eq 'failed') { throw 'PRIVATE-FAILURE' }
    if ($global:TurnFixtureMode -eq 'budget-exhausted') { throw 'Exceeded MaxToolIterations PRIVATE-FAILURE' }
    if ($global:TurnFixtureMode -eq 'stopped') { Start-Sleep -Seconds 5 }
    Write-Information -Tags 'ShpProgress' -MessageData ([pscustomobject]@{
        Kind = 'ToolCall'; Name = 'read_file'; Arguments = '{"path":"PRIVATE-PATH"}'
    })
    [pscustomobject]@{
        Content = 'PRIVATE-ANSWER'
        Usage = @{ PromptTokens = 10; CompletionTokens = 4; TotalTokens = 14 }
        CostUSD = $null
        Credits = $null
        ToolCalls = @()
        History = @()
    }
}
'@)
        $setup.Invoke() | Out-Null
        if ($setup.HadErrors) { throw $setup.Streams.Error[0] }
        $setup.Dispose()

        $settings = Get-DpDefaultSettings
        $settings.model = 'fixture'
        $settings.pushInstructions = $false
        $settings.workspaceContext = $false
        $settings.responseRetryCount = 0
        $settings.turnTranscript = $false
        $settings.skillRoots = @()
        $settings.instructionRoots = @()
        $settings.promptRoots = @()
        $script:DeskPilot = @{
            Settings = $settings
            Engine = @{
                Runspace = $runspace; UserPromptBridge = $null; ApprovalBridge = $null
                McpSupported = $false; BrowserState = $null; TerminalSession = $null
            }
            Diagnostics = @{ Log = (New-DpDiagnosticLog -MaxEntries 100 -MaxBytes 32768) }
            Intercom = $null
            Memory = @{ text = ''; updatedUtc = $null }
            DataDir = $null
            Version = '0.0.1'
            DefaultModel = 'fixture'
            Models = @()
            TurnRunning = $false
            CancelRequested = $false
            PendingApproval = $null
            PendingUserPrompt = $null
        }
        $conversation = New-DpConversation -Title 'Fixture'
        $stream = [System.IO.MemoryStream]::new()
        $script:RequestedOutcome = ''

        Mock Set-DpQuestionnaireTool { $false }
        Mock Set-DpWorkspaceTool { $false }
        Mock Set-DpTerminalTool { $false }
        Mock Get-DpBrowserRuntime { @{} }
        Mock Get-DpBrowserState { $null }
        Mock Set-DpBrowserTool { $false }
        Mock Test-DpBrowserActive { $false }
        Mock Get-DpDataDir { [string]$TestDrive }
        Mock Invoke-DpEngineCommand { $null }
        Mock Set-DpEngineLocation { $true }
        Mock Get-DpEngineWorkingDir { [string]$TestDrive }
        Mock Get-DpEngineEditedFile { @() }
        Mock Update-DpUsage {}
        Mock Close-DpBrowserSession {}
        Mock Invoke-DpPendingRequest {
            if ($script:RequestedOutcome -eq 'stopped') { $script:DeskPilot.CancelRequested = $true }
        }
    }

    AfterEach {
        $runspace.Close()
        $runspace.Dispose()
        $stream.Dispose()
    }

    It 'records the actual <Outcome> outcome without conversation content' -ForEach @(
        @{ Outcome = 'completed'; Frame = 'done' }
        @{ Outcome = 'failed'; Frame = 'error' }
        @{ Outcome = 'stopped'; Frame = 'stopped' }
        @{ Outcome = 'budget-exhausted'; Frame = 'stopped' }
    ) {
        $script:RequestedOutcome = $Outcome
        $runspace.SessionStateProxy.SetVariable('TurnFixtureMode', $Outcome)
        Invoke-DpTurn -Conversation $conversation -Prompt 'PRIVATE-PROMPT' -Stream $stream
        $wire = [System.Text.Encoding]::UTF8.GetString($stream.ToArray())
        $wire | Should -Match ('event: ' + $Frame)

        $entries = @(Get-DpDiagnosticLog -Log $script:DeskPilot.Diagnostics.Log)
        @($entries | Where-Object eventId -eq 'turn.started') | Should -HaveCount 1
        $last = @($entries | Where-Object eventId -eq "turn.$Outcome")
        $last | Should -HaveCount 1
        $last[0].context.outcome | Should -BeExactly $Outcome
        $last[0].context.conversationId | Should -BeExactly $conversation.id
        $last[0].context.turnId | Should -Match '^m_[0-9a-f]{10}$'
        $last[0].context.durationMs | Should -BeGreaterOrEqual 0
        ($entries | ConvertTo-Json -Depth 8) | Should -Not -Match 'PRIVATE-|"(?:prompt|arguments|authorization)"\s*:'

        if ($Outcome -eq 'completed') {
            $observed = @($entries | Where-Object eventId -eq 'tool.observed')
            $observed | Should -HaveCount 1
            $observed[0].context.toolSequence | Should -Be 1
            $last[0].context.promptTokens | Should -Be 10
            $last[0].context.costUSD | Should -BeNullOrEmpty
        }
        $script:DeskPilot.TurnRunning | Should -BeFalse
    }

    It 'refuses broader approval coverage on an old Engine before any Tool setup or Model call' {
        $script:DeskPilot.Settings.perCallApproval = $true
        $script:DeskPilot.Settings.approvalCoverage = 'mutating-tools'
        $runspace.SessionStateProxy.SetVariable('TurnFixtureMode', 'completed')
        Invoke-DpTurn -Conversation $conversation -Prompt 'PRIVATE-PROMPT' -Stream $stream
        $wire = [System.Text.Encoding]::UTF8.GetString($stream.ToArray())
        $wire | Should -Match 'event: error'
        $wire | Should -Match 'ToolCallApprover'
        $wire | Should -Not -Match 'event: done'
        Should -Invoke Set-DpWorkspaceTool -Times 0
        Should -Invoke Set-DpQuestionnaireTool -Times 0
        $conversation.messages.Count | Should -Be 0
    }
}
