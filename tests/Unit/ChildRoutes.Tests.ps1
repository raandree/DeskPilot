BeforeAll {
    Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '../../source/Private') -Filter '*.ps1' |
        ForEach-Object { . $_.FullName }
}

Describe 'Child Conversation routes' {
    BeforeEach {
        $script:prior = $script:DeskPilot
        $script:stopped = $false
        $script:approved = $false
        $controller = [pscustomobject]@{ Id = ('a' * 32); ConversationId = 'conversation' }
        $controller | Add-Member -MemberType ScriptMethod -Name Stop -Value { $script:stopped = $true }
        $controller | Add-Member -MemberType ScriptMethod -Name SubmitApproval -Value { param($Conversation, $Child, $Approval, $Fingerprint, $Allowed) $script:approved = $Allowed; $Conversation -ceq 'conversation' -and $Child -ceq ('a' * 32) -and $Approval -ceq 'approval' -and $Fingerprint -ceq ('b' * 64) }
        $controller | Add-Member -MemberType ScriptMethod -Name Snapshot -Value { '{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","conversationId":"conversation","status":"awaiting-approval","profile":"single-child-v3","budgetMode":"provider-estimate"}' }
        $script:DeskPilot = @{
            TurnRunning = $true; Settings = Get-DpDefaultSettings; DataDir = $TestDrive
            Conversations = @{ conversation = @{ id = 'conversation' } }
            Child = @{ Controller = $controller; Last = $null; Runtime = $null; Proof = $null; Health = $null; CleanupBlocked = $false; SetupJob = $null }
        }
        $script:stream = [IO.MemoryStream]::new()
    }

    AfterEach { $script:stream.Dispose(); $script:DeskPilot = $script:prior }

    It 'returns child status only within its owning Conversation' {
        Invoke-DpRouteHandler -Name getChildRun -RouteParams @{ id = 'conversation'; childId = ('a' * 32) } -Stream $script:stream
        $response = [Text.Encoding]::UTF8.GetString($script:stream.ToArray())
        $response | Should -Match '^HTTP/1.1 200'
        $response | Should -Match 'awaiting-approval'
    }

    It 'answers one exact child approval without using the parent approval bridge' {
        Invoke-DpRouteHandler -Name approveChildRun -RouteParams @{ id = 'conversation'; childId = ('a' * 32) } -Body @{
            approvalId = 'approval'; fingerprint = ('b' * 64); decision = 'approve'
        } -Stream $script:stream
        $response = [Text.Encoding]::UTF8.GetString($script:stream.ToArray())
        $response | Should -Match '^HTTP/1.1 202'
        $script:approved | Should -BeTrue
    }

    It 'refuses a child action for a different Conversation' {
        Invoke-DpRouteHandler -Name stopChildRun -RouteParams @{ id = 'different'; childId = ('a' * 32) } -Stream $script:stream
        $response = [Text.Encoding]::UTF8.GetString($script:stream.ToArray())
        $response | Should -Match '^HTTP/1.1 404'
        $script:stopped | Should -BeFalse
    }

    It 'closes only the current child authority on Stop' {
        Invoke-DpRouteHandler -Name stopChildRun -RouteParams @{ id = 'conversation'; childId = ('a' * 32) } -Stream $script:stream
        $response = [Text.Encoding]::UTF8.GetString($script:stream.ToArray())
        $response | Should -Match '^HTTP/1.1 202'
        $script:stopped | Should -BeTrue
    }

    It 'does not regenerate a child task as an ordinary uncontained Turn' {
        $script:DeskPilot.TurnRunning = $false
        $script:DeskPilot.Conversations.conversation.messages = @(@{ id = 'message'; role = 'user'; text = 'Child task.'; childRunId = ('a' * 32) })
        Mock Test-DpConversationWritable { @{ ok = $true } }
        Mock Reset-DpConversationForRerun { throw 'Must not rewrite child history.' }
        Mock Invoke-DpTurn { throw 'Must not fall back to an ordinary Turn.' }
        Invoke-DpRouteHandler -Name regenerateTurn -RouteParams @{ id = 'conversation' } -Stream $script:stream
        $response = [Text.Encoding]::UTF8.GetString($script:stream.ToArray())
        $response | Should -Match '^HTTP/1.1 409'
        $response | Should -Match 'child_consent_required'
        Should -Invoke Invoke-DpTurn -Times 0 -Exactly
        Should -Invoke Reset-DpConversationForRerun -Times 0 -Exactly
    }
}
