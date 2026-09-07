BeforeAll {
    Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '../../source/Private') -Filter '*.ps1' |
        ForEach-Object { . $_.FullName }
    $bootstrap = [runspacefactory]::CreateRunspace()
    $bootstrap.Open()
    try { $null = Initialize-DpUserPromptBridge -Runspace $bootstrap }
    finally { $bootstrap.Dispose() }

    function Get-TerminalScopeRequest {
        param([hashtable]$Patch = @{})
        $parameters = @{
            Tool = 'run_terminal_command'; Class = 'Terminal'; ConversationId = 'c-1'; TurnId = 't-1'
            ProjectName = 'Alpha'; Argument = @{ command = 'npm test'; workingDirectory = 'C:\projects\alpha'; policyId = 'policy-1' }
        }
        foreach ($key in $Patch.Keys) { $parameters[$key] = $Patch[$key] }
        New-DpApprovalRequest @parameters
    }
}

Describe 'Terminal Turn grant scope' {
    It 'binds the grant to scope without binding subsequent command text' {
        $first = Get-TerminalScopeRequest
        $second = Get-TerminalScopeRequest -Patch @{
            Argument = @{ command = 'npm run build'; workingDirectory = 'C:\projects\alpha'; policyId = 'policy-1' }
        }
        $first.scopeFingerprint | Should -Match '^[a-f0-9]{64}$'
        $second.scopeFingerprint | Should -BeExactly $first.scopeFingerprint
        $second.fingerprint | Should -Not -BeExactly $first.fingerprint
    }

    It 'separates <Name> from a prior grant' -ForEach @(
        @{ Name = 'Conversation'; Patch = @{ ConversationId = 'c-2' } }
        @{ Name = 'Turn'; Patch = @{ TurnId = 't-2' } }
        @{ Name = 'Project'; Patch = @{ ProjectName = 'Beta' } }
        @{ Name = 'Tool class'; Patch = @{ Class = 'Mcp' } }
        @{ Name = 'working directory'; Patch = @{ Argument = @{ command = 'npm test'; workingDirectory = 'C:\projects\beta'; policyId = 'policy-1' } } }
        @{ Name = 'execution policy'; Patch = @{ Argument = @{ command = 'npm test'; workingDirectory = 'C:\projects\alpha'; policyId = 'policy-2' } } }
    ) {
        $first = Get-TerminalScopeRequest
        $first.scopeFingerprint | Should -Not -BeNullOrEmpty
        (Get-TerminalScopeRequest -Patch $Patch).scopeFingerprint | Should -Not -BeExactly $first.scopeFingerprint
    }

    It 'invalidates grants on <Transition> even when no question is pending' -ForEach @(
        @{ Transition = 'Stop' }
        @{ Transition = 'completion' }
        @{ Transition = 'next Turn' }
    ) {
        $bridge = [DeskPilot.UserPromptBridge]::new()
        try {
            $bridge.BeginTurn('c-1')
            $bridge.GrantTurnScope('c-1', ('a' * 64)) | Should -BeTrue
            $bridge.HasTurnScope('c-1', ('a' * 64)) | Should -BeTrue
            $bridge.HasTurnScope('c-2', ('a' * 64)) | Should -BeFalse
            switch ($Transition) {
                'Stop' { $bridge.Cancel() }
                'completion' { $bridge.EndTurn() }
                'next Turn' { $bridge.BeginTurn('c-1') }
            }
            $bridge.HasTurnScope('c-1', ('a' * 64)) | Should -BeFalse
        }
        finally { $bridge.Dispose() }
    }
}

Describe 'Terminal Turn grant execution' {
    It 'uses <Scope> scope for two different risky commands' -ForEach @(
        @{ Scope = 'turn'; ExpectedRequests = 1 }
        @{ Scope = 'once'; ExpectedRequests = 2 }
    ) {
        $bridge = [DeskPilot.UserPromptBridge]::new()
        $bridge.BeginTurn('c-1')
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.Open()
        $shell = [powershell]::Create()
        $shell.Runspace = $runspace
        $marker = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.txt')
        $definitions = @('Get-DpPropertyValue', 'ConvertTo-DpTerminalExecution', 'New-DpApprovalRequest', 'Test-DpCommandSafe', 'Invoke-DpTerminalApprovalTool') |
            ForEach-Object { "function global:$_ {`n$((Get-Command $_).Definition)`n}" }
        $scriptText = @'
param($Bridge, $Marker)
$global:DeskPilotApprovalBridge = $Bridge
$global:DeskPilotApprovalContext = @{ conversationId = 'c-1'; turnId = 't-1'; project = 'Alpha'; workingDirectory = 'C:\projects\alpha'; policyId = 'policy-1' }
$global:DeskPilotSafeCommand = @()
$global:DeskPilotApprovalTimeoutMinutes = 1
$global:DeskPilotTerminalMarker = $Marker
$global:DeskPilotTerminalExecutor = {
    param($Command, $WorkingDirectory, $TimeoutSeconds)
    Add-Content -LiteralPath $global:DeskPilotTerminalMarker -Value $Command
    '{"exitCode":0}'
}
__DEFINITIONS__
Invoke-DpTerminalApprovalTool -Command 'npm test'
Invoke-DpTerminalApprovalTool -Command 'npm run build'
'@.Replace('__DEFINITIONS__', ($definitions -join "`n"))
        try {
            $null = $shell.AddScript($scriptText).AddArgument($bridge).AddArgument($marker)
            $invocation = $shell.BeginInvoke()
            $requests = 0
            $clock = [Diagnostics.Stopwatch]::StartNew()
            while (-not $invocation.IsCompleted -and $clock.Elapsed.TotalSeconds -lt 15) {
                $pending = $bridge.GetPendingRequest()
                if ($pending) {
                    $requests++
                    if ($requests -eq 1) { Test-Path -LiteralPath $marker | Should -BeFalse }
                    $bridge.SubmitAnswer('c-1', $pending.Id, (@{ decision = 'approve'; scope = $Scope } | ConvertTo-Json -Compress)) | Should -BeTrue
                }
                $null = $invocation.AsyncWaitHandle.WaitOne(10)
            }
            $invocation.IsCompleted | Should -BeTrue
            $results = @($shell.EndInvoke($invocation) | ForEach-Object { $_ | ConvertFrom-Json })
            $shell.HadErrors | Should -BeFalse -Because ($shell.Streams.Error | Out-String)
            $results | Should -HaveCount 2
            @($results.approved) | Should -Be @($true, $true)
            @(Get-Content -LiteralPath $marker) | Should -Be @('npm test', 'npm run build')
            $requests | Should -Be $ExpectedRequests
            $approvalRecords = @($shell.Streams.Information | Where-Object { $_.Tags -contains 'DeskPilotApproval' })
            $approved = @($approvalRecords.MessageData | Where-Object Status -eq 'approved')
            $approved | Should -HaveCount 2
            @($approved.Scope) | Should -Be @($Scope, $Scope)
            $approved[1].Source | Should -Be $(if ($Scope -eq 'turn') { 'turn-grant' } else { 'prompt' })
        }
        finally {
            $bridge.Cancel()
            $shell.Dispose()
            $runspace.Dispose()
            $bridge.Dispose()
        }
    }
}

Describe 'Terminal approval Activity' {
    It 'projects approval metadata without arbitrary payload fields' {
        $record = [Management.Automation.InformationRecord]::new([pscustomobject]@{
            Kind = 'TerminalApproval'; Status = 'approved'; Scope = 'turn'; Source = 'turn-grant'
            Command = 'secret-command-canary'; Raw = 'private-payload-canary'
        }, 'test')
        $record.Tags.Add('DeskPilotApproval')
        $frame = Get-DpStreamFrame -Record $record

        $frame.event | Should -BeExactly 'activity'
        $frame.Action.kind | Should -BeExactly 'approval'
        $frame.Action.scope | Should -BeExactly 'turn'
        $frame.Action.source | Should -BeExactly 'turn-grant'
        ($frame | ConvertTo-Json -Depth 6) | Should -Not -Match 'canary'
    }
}