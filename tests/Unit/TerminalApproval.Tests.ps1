#requires -Version 7.0

# Per-call approval for Terminal commands.
#
# The mechanism is the one ask_questions already uses in production: a
# DeskPilot-owned User Tool parks inside the Engine Runspace on a bridge until
# the Host Server supplies an answer. What makes it a boundary rather than a
# suggestion is that Invoke-Shp is given -DisableTerminal, so the Model has no
# built-in run_command to prefer instead.

BeforeAll {
    $privateRoot = Join-Path $PSScriptRoot '..' '..' 'source' 'Private'
    Get-ChildItem -Path $privateRoot -Filter '*.ps1' | ForEach-Object { . $_.FullName }

    function New-DpTestRequest {
        param(
            [string]$Command = 'Get-ChildItem',
            [string]$WorkingDirectory = 'C:\projects\alpha',
            [string]$ConversationId = 'c-1',
            [string]$TurnId = 't-1'
        )
        New-DpApprovalRequest -Tool 'run_command' -Class 'Terminal' `
            -Argument @{ command = $Command; workingDirectory = $WorkingDirectory } `
            -ProjectName 'Alpha' -ConversationId $ConversationId -TurnId $TurnId
    }
}

Describe 'New-DpApprovalRequest' -Tag 'Unit' {
    It 'summarizes only allow-listed fields' {
        $request = New-DpApprovalRequest -Tool 'run_command' -Class 'Terminal' `
            -Argument @{ command = 'git status'; workingDirectory = 'C:\p'; token = 'ghp_secret'; env = @{ AWS_SECRET = 'x' } } `
            -ProjectName 'Alpha' -ConversationId 'c-1' -TurnId 't-1'

        $request.summary.command | Should -Be 'git status'
        $request.summary.workingDirectory | Should -Be 'C:\p'
        $request.summary.project | Should -Be 'Alpha'
        $request.summary.Keys | Should -Not -Contain 'token'
        $request.summary.Keys | Should -Not -Contain 'env'
        # Nothing outside the summary may carry the raw arguments either.
        ($request | ConvertTo-Json -Depth 6) | Should -Not -Match 'ghp_secret'
        ($request | ConvertTo-Json -Depth 6) | Should -Not -Match 'AWS_SECRET'
    }

    It 'produces a stable fingerprint for the same action' {
        (New-DpTestRequest).fingerprint | Should -Be (New-DpTestRequest).fingerprint
        (New-DpTestRequest).fingerprint | Should -Match '^[0-9a-f]{64}$'
    }

    It 'produces a different fingerprint for a different command, Conversation or Turn' {
        $base = (New-DpTestRequest).fingerprint
        (New-DpTestRequest -Command 'rm -rf /').fingerprint | Should -Not -Be $base
        (New-DpTestRequest -ConversationId 'c-2').fingerprint | Should -Not -Be $base
        (New-DpTestRequest -TurnId 't-2').fingerprint | Should -Not -Be $base
    }

    It 'gives every request its own id so two identical commands are answered separately' {
        (New-DpTestRequest).id | Should -Not -Be (New-DpTestRequest).id
    }

    It 'bounds a very long command instead of forwarding all of it' {
        $request = New-DpTestRequest -Command ('a' * 5000)
        $request.summary.command.Length | Should -BeLessOrEqual 2100
        $request.summary.command | Should -Match 'truncated'
    }

    It 'states the risk in plain language without naming a secret' {
        (New-DpTestRequest).risk | Should -Not -BeNullOrEmpty
        (New-DpTestRequest).risk | Should -Match 'computer|files|command'
    }
}

Describe 'Approval grants' -Tag 'Unit' {
    BeforeEach {
        $script:state = New-DpApprovalState -TurnId 't-1'
        $script:request = New-DpTestRequest
    }

    It 'approves nothing without a grant' {
        (Resolve-DpApprovalGrant -State $script:state -Request $script:request).approved | Should -BeFalse
    }

    It 'lets an allow-once grant through exactly one matching action' {
        $script:state = Add-DpApprovalGrant -State $script:state -Request $script:request -Scope 'once'

        $first = Resolve-DpApprovalGrant -State $script:state -Request $script:request
        $first.approved | Should -BeTrue

        $second = Resolve-DpApprovalGrant -State $first.state -Request $script:request
        $second.approved | Should -BeFalse -Because 'an allow-once grant is consumed by the action it authorized'
    }

    It 'does not let an allow-once grant authorize a different command' {
        $script:state = Add-DpApprovalGrant -State $script:state -Request $script:request -Scope 'once'
        $other = New-DpTestRequest -Command 'Remove-Item -Recurse C:\'

        (Resolve-DpApprovalGrant -State $script:state -Request $other).approved | Should -BeFalse
    }

    It 'lets an allow-for-this-Turn grant through repeatedly within the same Turn' {
        $script:state = Add-DpApprovalGrant -State $script:state -Request $script:request -Scope 'turn'

        $first = Resolve-DpApprovalGrant -State $script:state -Request (New-DpTestRequest -Command 'git status')
        $first.approved | Should -BeTrue
        (Resolve-DpApprovalGrant -State $first.state -Request (New-DpTestRequest -Command 'git log')).approved | Should -BeTrue
    }

    It 'scopes a Turn grant to the Tool class it was given for' {
        $script:state = Add-DpApprovalGrant -State $script:state -Request $script:request -Scope 'turn'
        $mcp = New-DpApprovalRequest -Tool 'mcp_x_write' -Class 'Mcp' -Argument @{ command = 'anything' } `
            -ProjectName 'Alpha' -ConversationId 'c-1' -TurnId 't-1'

        (Resolve-DpApprovalGrant -State $script:state -Request $mcp).approved | Should -BeFalse
    }

    It 'does not carry a Turn grant into the next Turn' {
        $script:state = Add-DpApprovalGrant -State $script:state -Request $script:request -Scope 'turn'
        $nextTurn = New-DpTestRequest -TurnId 't-2'

        (Resolve-DpApprovalGrant -State $script:state -Request $nextTurn).approved | Should -BeFalse
    }

    It 'refuses an answer that belongs to another Conversation' {
        $script:state = Add-DpApprovalGrant -State $script:state -Request $script:request -Scope 'once'
        $crossConversation = New-DpTestRequest -ConversationId 'c-999'

        (Resolve-DpApprovalGrant -State $script:state -Request $crossConversation).approved | Should -BeFalse
    }

    It 'starts a new Turn with no grants at all' {
        $script:state = Add-DpApprovalGrant -State $script:state -Request $script:request -Scope 'turn'
        $fresh = New-DpApprovalState -TurnId 't-2'

        @($fresh.grants).Count | Should -Be 0
    }
}

Describe 'Invoke-DpTerminalApprovalTool' -Tag 'Unit' {
    BeforeEach {
        $script:marker = Join-Path $TestDrive ('ran-' + [guid]::NewGuid().ToString('N') + '.txt')
        $script:bridge = New-Object -TypeName 'DeskPilot.UserPromptBridge'
        $script:bridge.BeginTurn('c-1')
        # The executor stands in for the Engine's own run_command. Production
        # delegates to it after approval; the test only needs to know whether the
        # side effect happened.
        $global:DeskPilotTerminalExecutor = {
            param($Command, $WorkingDirectory, $TimeoutSeconds)
            Set-Content -LiteralPath $script:marker -Value $Command -Encoding utf8
            '{"exitCode":0,"stdout":"done","stderr":""}'
        }
        $global:DeskPilotApprovalBridge = $script:bridge
        $global:DeskPilotApprovalState = New-DpApprovalState -TurnId 't-1'
        $global:DeskPilotApprovalContext = @{ conversationId = 'c-1'; turnId = 't-1'; project = 'Alpha'; workingDirectory = 'C:\projects\alpha' }
    }

    AfterEach {
        $script:bridge.Dispose()
        Remove-Variable -Name DeskPilotTerminalExecutor, DeskPilotApprovalBridge, DeskPilotApprovalState, DeskPilotApprovalContext -Scope Global -ErrorAction SilentlyContinue
    }

    It 'does not run the command until the answer arrives' {
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.Open()
        $runspace.SessionStateProxy.SetVariable('DeskPilotApprovalBridge', $script:bridge)
        $runspace.SessionStateProxy.SetVariable('DeskPilotApprovalState', $global:DeskPilotApprovalState)
        $runspace.SessionStateProxy.SetVariable('DeskPilotApprovalContext', $global:DeskPilotApprovalContext)
        $runspace.SessionStateProxy.SetVariable('DeskPilotTerminalMarker', $script:marker)
        # The executor is built inside the runspace: a scriptblock carries an
        # affinity to the runspace that created it and cannot be invoked across.
        $definitions = @('New-DpApprovalRequest', 'New-DpApprovalState', 'Resolve-DpApprovalGrant', 'Add-DpApprovalGrant', 'Invoke-DpTerminalApprovalTool') |
            ForEach-Object { "function global:$_ {`n$((Get-Command $_).Definition)`n}" }
        $executor = '$global:DeskPilotTerminalExecutor = { param($Command, $WorkingDirectory, $TimeoutSeconds) Set-Content -LiteralPath $global:DeskPilotTerminalMarker -Value $Command -Encoding utf8; ''{"exitCode":0}'' }'

        $shell = [powershell]::Create()
        $shell.Runspace = $runspace
        try {
            $null = $shell.AddScript(($definitions -join "`n") + "`n$executor`nInvoke-DpTerminalApprovalTool -Command 'Get-ChildItem'")
            $async = $shell.BeginInvoke()

            # Wait for the tool to park on the bridge, then prove nothing has run.
            $pending = $null
            $deadline = [datetime]::UtcNow.AddSeconds(10)
            while (-not $pending -and [datetime]::UtcNow -lt $deadline) {
                $pending = $script:bridge.GetPendingRequest()
                if (-not $pending) { Start-Sleep -Milliseconds 20 }
            }

            $pending | Should -Not -BeNullOrEmpty -Because 'the Tool must ask before it acts'
            Test-Path -LiteralPath $script:marker | Should -BeFalse -Because 'the command must not run while approval is pending'

            $answer = @{ decision = 'approve'; scope = 'once' } | ConvertTo-Json -Compress
            $script:bridge.SubmitAnswer('c-1', $pending.Id, $answer) | Should -BeTrue

            $null = $shell.EndInvoke($async)
            Test-Path -LiteralPath $script:marker | Should -BeTrue -Because 'an approved command runs'
        }
        finally {
            $shell.Dispose()
            $runspace.Dispose()
        }
    }

    It 'returns a recoverable result and no side effect when the user denies it' {
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.Open()
        $runspace.SessionStateProxy.SetVariable('DeskPilotApprovalBridge', $script:bridge)
        $runspace.SessionStateProxy.SetVariable('DeskPilotApprovalState', $global:DeskPilotApprovalState)
        $runspace.SessionStateProxy.SetVariable('DeskPilotApprovalContext', $global:DeskPilotApprovalContext)
        $runspace.SessionStateProxy.SetVariable('DeskPilotTerminalMarker', $script:marker)
        $definitions = @('New-DpApprovalRequest', 'New-DpApprovalState', 'Resolve-DpApprovalGrant', 'Add-DpApprovalGrant', 'Invoke-DpTerminalApprovalTool') |
            ForEach-Object { "function global:$_ {`n$((Get-Command $_).Definition)`n}" }
        $executor = '$global:DeskPilotTerminalExecutor = { param($Command, $WorkingDirectory, $TimeoutSeconds) Set-Content -LiteralPath $global:DeskPilotTerminalMarker -Value $Command -Encoding utf8; ''{"exitCode":0}'' }'

        $shell = [powershell]::Create()
        $shell.Runspace = $runspace
        try {
            $null = $shell.AddScript(($definitions -join "`n") + "`n$executor`nInvoke-DpTerminalApprovalTool -Command 'Remove-Item -Recurse C:\'")
            $async = $shell.BeginInvoke()

            $pending = $null
            $deadline = [datetime]::UtcNow.AddSeconds(10)
            while (-not $pending -and [datetime]::UtcNow -lt $deadline) {
                $pending = $script:bridge.GetPendingRequest()
                if (-not $pending) { Start-Sleep -Milliseconds 20 }
            }
            $pending | Should -Not -BeNullOrEmpty

            $null = $script:bridge.SubmitAnswer('c-1', $pending.Id, (@{ decision = 'deny' } | ConvertTo-Json -Compress))
            $result = ($shell.EndInvoke($async) | Select-Object -First 1)

            Test-Path -LiteralPath $script:marker | Should -BeFalse
            $shell.HadErrors | Should -BeFalse -Because 'a denial is a Tool result, not a failed Turn'
            $parsed = $result | ConvertFrom-Json
            $parsed.approved | Should -BeFalse
            $parsed.error | Should -Match 'declined|denied'
        }
        finally {
            $shell.Dispose()
            $runspace.Dispose()
        }
    }

    It 'runs without asking when a Turn grant already covers the class' {
        $global:DeskPilotApprovalState = Add-DpApprovalGrant -State $global:DeskPilotApprovalState `
            -Request (New-DpTestRequest) -Scope 'turn'

        $result = Invoke-DpTerminalApprovalTool -Command 'git status'

        Test-Path -LiteralPath $script:marker | Should -BeTrue
        $script:bridge.Waiting | Should -BeFalse
        ($result | ConvertFrom-Json).approved | Should -BeTrue
    }

    It 'refuses without running anything when the bridge is not active' {
        $script:bridge.EndTurn()

        $result = Invoke-DpTerminalApprovalTool -Command 'git status'

        Test-Path -LiteralPath $script:marker | Should -BeFalse
        ($result | ConvertFrom-Json).approved | Should -BeFalse
    }

    It 'never puts the command itself into the recorded grant' {
        $state = Add-DpApprovalGrant -State (New-DpApprovalState -TurnId 't-1') -Request (New-DpTestRequest -Command 'echo hunter2') -Scope 'turn'
        ($state | ConvertTo-Json -Depth 6) | Should -Not -Match 'hunter2'
    }
}

Describe 'Per-call approval Setting' -Tag 'Unit' {
    It 'is off until the whole path is wired, so Terminal behaviour is unchanged' {
        (Get-DpDefaultSettings).perCallApproval | Should -BeFalse
    }

    It 'accepts a boolean and refuses nothing else' {
        $merged = Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch @{ perCallApproval = $true }
        $merged.perCallApproval | Should -BeTrue
    }
}
