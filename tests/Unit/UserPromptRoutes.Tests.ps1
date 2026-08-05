#requires -Version 7.0

BeforeAll {
    $privateRoot = Join-Path $PSScriptRoot '..' '..' 'source' 'Private'
    Get-ChildItem -Path $privateRoot -Filter '*.ps1' | ForEach-Object { . $_.FullName }
}

Describe 'submitUserPrompt answer route' -Tag 'Unit' {
    BeforeEach {
        $conversation = New-DpConversation -Title 'Ask-User test'
        $script:submittedAnswer = $null
        $bridge = [pscustomobject]@{}
        $bridge | Add-Member -MemberType ScriptMethod -Name SubmitAnswer -Value {
            param($conversationId, $questionId, $answer)
            $script:submittedAnswer = @{
                ConversationId = $conversationId
                QuestionId     = $questionId
                Answer         = $answer
            }
            $questionId -eq 'q_1'
        }
        $script:DeskPilot = @{
            Conversations = @{ $conversation.id = $conversation }
            TurnRunning   = $true
            Engine        = @{ UserPromptBridge = $bridge }
        }
        $script:responseStream = [System.IO.MemoryStream]::new()
    }

    AfterEach {
        $script:responseStream.Dispose()
        $script:DeskPilot = $null
    }

    It 'accepts the answer for the matching pending question' {
        $body = [pscustomobject]@{ questionId = 'q_1'; answer = 'Berlin' }
        $invokeParams = @{
            Name        = 'submitUserPrompt'
            RouteParams = @{ id = $conversation.id }
            Body        = $body
            Stream      = $script:responseStream
        }

        Invoke-DpRouteHandler @invokeParams

        $response = [System.Text.Encoding]::UTF8.GetString($script:responseStream.ToArray())
        $response | Should -Match '^HTTP/1\.1 202 Accepted'
        $script:submittedAnswer | Should -Not -BeNullOrEmpty
        $script:submittedAnswer.ConversationId | Should -Be $conversation.id
        $script:submittedAnswer.Answer | Should -Be 'Berlin'
    }

    It 'rejects an answer for a stale question id' {
        $body = [pscustomobject]@{ questionId = 'q_stale'; answer = 'Berlin' }
        $invokeParams = @{
            Name        = 'submitUserPrompt'
            RouteParams = @{ id = $conversation.id }
            Body        = $body
            Stream      = $script:responseStream
        }

        Invoke-DpRouteHandler @invokeParams

        $response = [System.Text.Encoding]::UTF8.GetString($script:responseStream.ToArray())
        $response | Should -Match '^HTTP/1\.1 409 Conflict'
        $json = ($response -split "`r`n`r`n", 2)[1] | ConvertFrom-Json
        $json.error.code | Should -Be 'stale_question'
    }
}
