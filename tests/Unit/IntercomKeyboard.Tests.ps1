#requires -Version 7.0

BeforeAll {
    # The module runs under Set-StrictMode -Version Latest (source/Prefix.ps1),
    # where reading a missing hashtable key is a terminating error rather than
    # $null.
    Set-StrictMode -Version Latest
    $privateRoot = Join-Path $PSScriptRoot '..' '..' 'source' 'Private'
    Get-ChildItem -Path $privateRoot -Filter '*.ps1' | ForEach-Object { . $_.FullName }

    function New-TestCallback {
        [CmdletBinding()]
        [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'A test helper that builds an in-memory Telegram update; it changes nothing.')]
        param([string]$ChatId = '111', [string]$Data = 'q|abcd1234|0', [string]$CallbackId = 'cb1')

        [pscustomobject]@{
            update_id      = 7
            callback_query = [pscustomobject]@{
                id      = $CallbackId
                data    = $Data
                from    = [pscustomobject]@{ first_name = 'Randy'; username = 'randree3' }
                message = [pscustomobject]@{
                    message_id = 42
                    chat       = [pscustomobject]@{ id = $ChatId }
                }
            }
        }
    }
}

Describe 'Inline keyboards' -Tag 'Unit' {
    It 'lays the choices out one per row by default' {
        $keyboard = Get-DpIntercomKeyboard -Choice @(
            @{ label = 'Munich'; data = 'q|t|0' }
            @{ label = 'Berlin'; data = 'q|t|1' }
        )

        @($keyboard.inline_keyboard).Count | Should -Be 2
        $keyboard.inline_keyboard[0][0].text | Should -Be 'Munich'
        $keyboard.inline_keyboard[0][0].callback_data | Should -Be 'q|t|0'
    }

    It 'packs several buttons into a row when asked' {
        $keyboard = Get-DpIntercomKeyboard -PerRow 2 -Choice @(
            @{ label = 'a'; data = '1' }
            @{ label = 'b'; data = '2' }
            @{ label = 'c'; data = '3' }
        )

        @($keyboard.inline_keyboard).Count | Should -Be 2
        @($keyboard.inline_keyboard[0]).Count | Should -Be 2
        @($keyboard.inline_keyboard[1]).Count | Should -Be 1
    }

    It 'returns nothing when there is nothing to offer' {
        Get-DpIntercomKeyboard -Choice @() | Should -BeNullOrEmpty
    }

    It 'drops the whole keyboard rather than ship a button Telegram will reject' {
        # callback_data is capped at 64 bytes; a button over it fails silently when
        # tapped, which is worse than having no button at all.
        Get-DpIntercomKeyboard -Choice @(
            @{ label = 'fine'; data = 'q|t|0' }
            @{ label = 'too long'; data = ('x' * 65) }
        ) | Should -BeNullOrEmpty
    }

    It 'truncates a label too wide for a phone' {
        $keyboard = Get-DpIntercomKeyboard -Choice @(@{ label = ('y' * 80); data = 'd' })

        $keyboard.inline_keyboard[0][0].text.Length | Should -Be 64
        $keyboard.inline_keyboard[0][0].text | Should -Match '\.\.\.$'
    }
}

Describe 'ConvertFrom-DpIntercomUpdate on a button tap' -Tag 'Unit' {
    It 'reads a tap as its own kind and keeps the id needed to answer it' {
        $result = ConvertFrom-DpIntercomUpdate -Update (New-TestCallback) -AllowedChatId '111'

        $result.kind | Should -Be 'callback'
        $result.text | Should -Be 'q|abcd1234|0'
        $result.callbackId | Should -Be 'cb1'
        $result.chatId | Should -Be '111'
    }

    It 'rejects a tap from a chat that is not allow-listed before reading its data' {
        $result = ConvertFrom-DpIntercomUpdate -Update (New-TestCallback -ChatId '999') -AllowedChatId '111'

        $result.kind | Should -Be 'rejected'
        $result.text | Should -BeNullOrEmpty
        $result.fromName | Should -Be 'Randy @randree3'
    }
}

Describe 'Invoke-DpIntercomCallback' -Tag 'Unit' {
    BeforeEach {
        $script:sent = [System.Collections.Generic.List[object]]::new()
        Mock Send-DpIntercomMessage { $script:sent.Add(@{ Title = $Title; Line = @($Line) }); $true }

        $script:submitted = $null
        $bridge = [pscustomobject]@{}
        $bridge | Add-Member -MemberType ScriptMethod -Name 'SubmitAnswer' -Value {
            param($ConversationId, $QuestionId, $Answer)
            $script:submitted = $Answer
            $true
        }

        $script:DeskPilot = @{
            Settings      = @{ intercom = @{ maxMessagesPerHour = 60; chatId = '111' } }
            Conversations = @{ c1 = @{ id = 'c1'; title = 'Lab work' } }
            TurnRunning   = $true
            Engine        = @{ UserPromptBridge = $bridge }
            Intercom      = @{
                Outbound        = [System.Collections.Generic.Queue[hashtable]]::new()
                Log             = [System.Collections.Generic.List[object]]::new()
                Token           = 'test-token'
                ConversationId  = $null
                PendingQuestion = @{
                    id             = 'req1'
                    conversationId = 'c1'
                    messageId      = 42
                    askedUtc       = [DateTime]::UtcNow
                    token          = 'abcd1234'
                    options        = @('Munich', 'Berlin')
                }
            }
        }
    }

    AfterEach { $script:DeskPilot = $null }

    It 'answers Telegram so the button stops spinning' {
        Invoke-DpIntercomCallback -Command @{ kind = 'callback'; callbackId = 'cb1'; text = 'q|abcd1234|1' }

        $queued = @($script:DeskPilot.Intercom.Outbound.ToArray())
        $queued[0].operation | Should -Be 'answerCallbackQuery'
        $queued[0].payload.callback_query_id | Should -Be 'cb1'
    }

    It 'submits the label behind the tapped option, not its index' {
        Invoke-DpIntercomCallback -Command @{ kind = 'callback'; callbackId = 'cb1'; text = 'q|abcd1234|1' }

        $script:submitted | Should -Be 'Berlin'
        $script:DeskPilot.Intercom.PendingQuestion | Should -BeNullOrEmpty
    }

    It 'refuses a button from a question that has already moved on' {
        # Old buttons stay on screen in Telegram forever, so a stale tap must never
        # answer whatever question happens to be waiting now.
        $script:DeskPilot.Intercom.PendingQuestion.token = 'ffffffff'

        Invoke-DpIntercomCallback -Command @{ kind = 'callback'; callbackId = 'cb1'; text = 'q|abcd1234|1' }

        $script:submitted | Should -BeNullOrEmpty
        $script:sent[0].Title | Should -Be 'That question has moved on.'
    }

    It 'refuses a tap when no question is waiting at all' {
        $script:DeskPilot.Intercom.PendingQuestion = $null

        Invoke-DpIntercomCallback -Command @{ kind = 'callback'; callbackId = 'cb1'; text = 'q|abcd1234|0' }

        $script:submitted | Should -BeNullOrEmpty
        $script:sent[0].Title | Should -Be 'That question has moved on.'
    }

    It 'refuses an option index outside the list it was given' {
        Invoke-DpIntercomCallback -Command @{ kind = 'callback'; callbackId = 'cb1'; text = 'q|abcd1234|9' }

        $script:submitted | Should -BeNullOrEmpty
        $script:sent[0].Title | Should -Be 'I did not recognise that choice.'
    }

    It 'switches conversation when a chat button is tapped' {
        Invoke-DpIntercomCallback -Command @{ kind = 'callback'; callbackId = 'cb1'; text = 'k|c1' }

        $script:DeskPilot.Intercom.ConversationId | Should -Be 'c1'
        $script:sent[0].Title | Should -Be 'Switched.'
    }

    It 'says so when a chat button points at something that has gone' {
        Invoke-DpIntercomCallback -Command @{ kind = 'callback'; callbackId = 'cb1'; text = 'k|gone' }

        $script:DeskPilot.Intercom.ConversationId | Should -BeNullOrEmpty
        $script:sent[0].Title | Should -Be 'I could not find that one.'
    }

    It 'ignores data it does not recognise without replying' {
        Invoke-DpIntercomCallback -Command @{ kind = 'callback'; callbackId = 'cb1'; text = 'zzz|1' }

        $script:sent.Count | Should -Be 0
        @($script:DeskPilot.Intercom.Log)[-1].kind | Should -Be 'callback-unknown'
    }
}

Describe 'Send-DpIntercomQuestion keyboards' -Tag 'Unit' {
    BeforeEach {
        $script:captured = $null
        Mock Send-DpIntercomMessage {
            $script:captured = @{
                Title       = $Title
                Line        = @($Line)
                Keyboard    = $Keyboard
                HasKeyboard = $PSBoundParameters.ContainsKey('Keyboard')
            }
            $true
        }
        Mock Test-DpIntercomProject { @{ allowed = $true; reason = '' } }

        $script:DeskPilot = @{
            Settings = @{ intercom = @{ questionTimeoutMinutes = 60 } }
            Intercom = @{ Running = $true; PendingQuestion = $null }
        }
    }

    AfterEach { $script:DeskPilot = $null }

    It 'offers a button per option for a single-choice question' {
        $questionnaire = @{
            title     = 'Location'
            questions = @(@{ header = 'Where'; question = 'Which site?'; options = @(@{ label = 'Munich'; description = '' }, @{ label = 'Berlin'; description = '' }); multiSelect = $false; allowFreeformInput = $true })
        }

        Send-DpIntercomQuestion -RequestId 'r1' -ConversationId 'c1' -Questionnaire $questionnaire

        @($script:captured['Keyboard'].inline_keyboard).Count | Should -Be 2
        # The nonce ties those buttons to this question and nothing else.
        $script:captured['Keyboard'].inline_keyboard[0][0].callback_data |
            Should -Be "q|$($script:DeskPilot.Intercom.PendingQuestion.token)|0"
        ($script:captured['Line'] -join ' ') | Should -Match 'Tap an answer'
    }

    It 'falls back to a written reply for a multi-select question' {
        $questionnaire = @{
            title     = 'Pick'
            questions = @(@{ header = 'Which'; question = 'Choose any'; options = @(@{ label = 'a'; description = '' }, @{ label = 'b'; description = '' }); multiSelect = $true; allowFreeformInput = $false })
        }

        Send-DpIntercomQuestion -RequestId 'r1' -ConversationId 'c1' -Questionnaire $questionnaire

        $script:captured['HasKeyboard'] | Should -BeFalse
        $script:DeskPilot.Intercom.PendingQuestion.token | Should -BeNullOrEmpty
        ($script:captured['Line'] -join ' ') | Should -Match 'Reply to this message'
    }

    It 'falls back to a written reply when there is more than one question' {
        $questionnaire = @{
            title     = 'Two things'
            questions = @(
                @{ header = 'One'; question = 'First?'; options = @(@{ label = 'a'; description = '' }); multiSelect = $false; allowFreeformInput = $true }
                @{ header = 'Two'; question = 'Second?'; options = @(@{ label = 'b'; description = '' }); multiSelect = $false; allowFreeformInput = $true }
            )
        }

        Send-DpIntercomQuestion -RequestId 'r1' -ConversationId 'c1' -Questionnaire $questionnaire

        $script:captured['HasKeyboard'] | Should -BeFalse
    }

    It 'sends a free-text question exactly as before' {
        $questionnaire = @{
            title     = 'Anything'
            questions = @(@{ header = 'Q'; question = 'What next?'; options = @(); multiSelect = $false; allowFreeformInput = $true })
        }

        Send-DpIntercomQuestion -RequestId 'r1' -ConversationId 'c1' -Questionnaire $questionnaire

        $script:captured['HasKeyboard'] | Should -BeFalse
        ($script:captured['Line'] -join ' ') | Should -Match 'Reply to this message'
    }
}
