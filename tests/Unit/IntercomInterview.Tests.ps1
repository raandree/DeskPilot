#requires -Version 7.0

BeforeAll {
    # The module runs under Set-StrictMode -Version Latest (source/Prefix.ps1),
    # where reading a missing hashtable key is a terminating error rather than
    # $null.
    Set-StrictMode -Version Latest
    $privateRoot = Join-Path $PSScriptRoot '..' '..' 'source' 'Private'
    Get-ChildItem -Path $privateRoot -Filter '*.ps1' | ForEach-Object { . $_.FullName }

    function Invoke-TestTap {
        [CmdletBinding()]
        [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'A test helper that taps an in-memory button.')]
        param([Parameter(Mandatory)][string]$Choice)

        $token = $script:DeskPilot.Intercom.PendingQuestion.token
        Invoke-DpIntercomCallback -Command @{ kind = 'callback'; callbackId = 'cb'; text = "q|$token|$Choice" }
    }
}

Describe 'ConvertTo-DpQuestionnaireAnswer' -Tag 'Unit' {
    It 'answers an unstructured Questionnaire as bare text, as the browser does' {
        $question = @(@{ header = 'Question'; selectedOptions = @(); freeText = '  the middle one  ' })

        ConvertTo-DpQuestionnaireAnswer -Question $question -Structured $false | Should -Be 'the middle one'
    }

    It 'falls back to the chosen option when an unstructured answer was a tap' {
        $question = @(@{ header = 'Question'; selectedOptions = @('Berlin'); freeText = '' })

        ConvertTo-DpQuestionnaireAnswer -Question $question -Structured $false | Should -Be 'Berlin'
    }

    It 'produces the structured shape the browser wizard submits' {
        $questions = @(
            @{ header = 'Purpose'; selectedOptions = @('Demo'); freeText = '' }
            @{ header = 'Budget'; selectedOptions = @(); freeText = 'a weekend' }
        )

        $json = ConvertTo-DpQuestionnaireAnswer -Question $questions -Structured $true
        $parsed = $json | ConvertFrom-Json

        @($parsed.answers).Count | Should -Be 2
        $parsed.answers[0].header | Should -Be 'Purpose'
        @($parsed.answers[0].selectedOptions) | Should -Be @('Demo')
        $parsed.answers[1].freeText | Should -Be 'a weekend'
    }

    It 'keeps a single selected option as a list, not a bare string' {
        # ConvertTo-Json collapses a one-element collection that lost its
        # array-ness, and the browser contract is a list either way.
        $json = ConvertTo-DpQuestionnaireAnswer -Question @(@{ header = 'H'; selectedOptions = @('only'); freeText = '' }) -Structured $true

        $json | Should -Match '"selectedOptions":\["only"\]'
    }
}

Describe 'Intercom step-through interview' -Tag 'Unit' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $script:sent = [System.Collections.Generic.List[object]]::new()
        $script:submitted = $null
        Mock Send-DpIntercomMessage {
            $script:sent.Add([pscustomobject]@{
                    Title       = $Title
                    Line        = @($Line)
                    Body        = $Body
                    Kind        = $Kind
                    Keyboard    = $Keyboard
                    HasKeyboard = ($null -ne $Keyboard)
                })
            $true
        }
        Mock Test-DpIntercomProject { @{ allowed = $true; reason = '' } }

        $bridge = [pscustomobject]@{}
        $bridge | Add-Member -MemberType ScriptMethod -Name 'SubmitAnswer' -Value {
            param($ConversationId, $QuestionId, $Answer)
            $script:submitted = $Answer
            $true
        }

        $script:DeskPilot = @{
            Settings    = @{ intercom = @{ questionTimeoutMinutes = 60; chatId = '111' } }
            TurnRunning = $true
            Engine      = @{ UserPromptBridge = $bridge }
            Intercom    = @{
                Running         = $true
                PendingQuestion = $null
                Outbound        = [System.Collections.Generic.Queue[hashtable]]::new()
                Log             = [System.Collections.Generic.List[object]]::new()
                Token           = 'test-token'
                LastActivityUtc = [DateTime]::UtcNow
                StallNotified   = $false
            }
        }

        $script:threeQuestions = @{
            title      = 'Design interview'
            structured = $true
            questions  = @(
                @{ header = 'Purpose'; question = 'What is it for?'; options = @(@{ label = 'Demo'; description = '' }, @{ label = 'Spike'; description = '' }); multiSelect = $false; allowFreeformInput = $false }
                @{ header = 'Success'; question = 'What would success be?'; options = @(); multiSelect = $false; allowFreeformInput = $true }
                @{ header = 'Risks'; question = 'What would kill it?'; options = @(@{ label = 'Slow'; description = '' }, @{ label = 'Costly'; description = '' }); multiSelect = $true; allowFreeformInput = $false }
            )
        }
    }

    AfterEach { $script:DeskPilot = $null }

    It 'walks all three questions and submits once, at the end' {
        Send-DpIntercomQuestion -RequestId 'r1' -ConversationId 'c1' -Questionnaire $script:threeQuestions

        Invoke-TestTap -Choice '0'                               # Purpose -> Demo
        $script:submitted | Should -BeNullOrEmpty                # nothing yet
        $script:DeskPilot.Intercom.PendingQuestion.step | Should -Be 1

        $null = Submit-DpIntercomAnswer -Answer 'a stranger gets a rainy image'
        $script:DeskPilot.Intercom.PendingQuestion.step | Should -Be 2

        Invoke-TestTap -Choice '1'                               # Risks -> Costly (toggle)
        $script:submitted | Should -BeNullOrEmpty                 # multi-select waits for Done
        Invoke-TestTap -Choice 'd'

        $script:DeskPilot.Intercom.PendingQuestion | Should -BeNullOrEmpty
        $parsed = $script:submitted | ConvertFrom-Json
        @($parsed.answers).Count | Should -Be 3
        @($parsed.answers[0].selectedOptions) | Should -Be @('Demo')
        $parsed.answers[1].freeText | Should -Be 'a stranger gets a rainy image'
        @($parsed.answers[2].selectedOptions) | Should -Be @('Costly')
    }

    It 'toggles a multi-select option off when it is tapped twice' {
        Send-DpIntercomQuestion -RequestId 'r1' -ConversationId 'c1' -Questionnaire $script:threeQuestions
        Invoke-TestTap -Choice '0'
        $null = Submit-DpIntercomAnswer -Answer 'anything'

        Invoke-TestTap -Choice '0'
        Invoke-TestTap -Choice '1'
        Invoke-TestTap -Choice '0'

        @($script:DeskPilot.Intercom.PendingQuestion.questions[2].selectedOptions) | Should -Be @('Costly')
    }

    It 'reports what a multi-select tap did on the tap acknowledgement itself' {
        # A toast costs no message and no queue slot; re-sending the question per
        # tap would cost both.
        Send-DpIntercomQuestion -RequestId 'r1' -ConversationId 'c1' -Questionnaire $script:threeQuestions
        Invoke-TestTap -Choice '0'
        $null = Submit-DpIntercomAnswer -Answer 'anything'
        $script:DeskPilot.Intercom.Outbound.Clear()

        Invoke-TestTap -Choice '1'

        $ack = @($script:DeskPilot.Intercom.Outbound.ToArray())[0]
        $ack.operation | Should -Be 'answerCallbackQuery'
        $ack.payload.text | Should -Be 'Added: Costly'
    }

    It 'refuses Done before anything is picked' {
        Send-DpIntercomQuestion -RequestId 'r1' -ConversationId 'c1' -Questionnaire $script:threeQuestions
        Invoke-TestTap -Choice '0'
        $null = Submit-DpIntercomAnswer -Answer 'anything'

        Invoke-TestTap -Choice 'd'

        $script:DeskPilot.Intercom.PendingQuestion | Should -Not -BeNullOrEmpty
        @($script:sent)[-1].Title | Should -Be 'Pick at least one before Done.'
    }

    It 'maps a typed number onto the option that number was printed against' {
        Send-DpIntercomQuestion -RequestId 'r1' -ConversationId 'c1' -Questionnaire $script:threeQuestions

        $null = Submit-DpIntercomAnswer -Answer '2'

        @($script:DeskPilot.Intercom.PendingQuestion.questions[0].selectedOptions) | Should -Be @('Spike')
        $script:DeskPilot.Intercom.PendingQuestion.step | Should -Be 1
    }

    It 'refuses words on a question that only accepts one of its choices' {
        # The browser wizard would not let this be submitted either, so sending it
        # would hand the agent an answer the machine would have rejected.
        Send-DpIntercomQuestion -RequestId 'r1' -ConversationId 'c1' -Questionnaire $script:threeQuestions

        $null = Submit-DpIntercomAnswer -Answer 'something else entirely'

        $script:DeskPilot.Intercom.PendingQuestion.step | Should -Be 0
        @($script:sent)[-1].Title | Should -Be 'I need one of the choices.'
    }

    It 'moves the reply nonce to each new step so an old message cannot answer the new question' {
        Send-DpIntercomQuestion -RequestId 'r1' -ConversationId 'c1' -Questionnaire $script:threeQuestions
        $firstToken = $script:DeskPilot.Intercom.PendingQuestion.token

        Invoke-TestTap -Choice '0'

        $script:DeskPilot.Intercom.PendingQuestion.token | Should -Not -Be $firstToken
        # Capture 'question' re-arms the reply target for the new message.
        $script:DeskPilot.Intercom.PendingQuestion.messageId | Should -Be 0
    }

    It 'refuses a tap carrying the nonce of a step already answered' {
        Send-DpIntercomQuestion -RequestId 'r1' -ConversationId 'c1' -Questionnaire $script:threeQuestions
        $staleToken = $script:DeskPilot.Intercom.PendingQuestion.token
        Invoke-TestTap -Choice '0'

        Invoke-DpIntercomCallback -Command @{ kind = 'callback'; callbackId = 'cb'; text = "q|$staleToken|1" }

        $script:DeskPilot.Intercom.PendingQuestion.step | Should -Be 1
        @($script:sent)[-1].Title | Should -Be 'That question has moved on.'
    }

    It 'offers a way out when none of the choices fit' {
        # ConvertTo-DpQuestionnaire defaults allowFreeformInput to false whenever a
        # question has options, so without this most option questions would refuse
        # typing outright and the operator would have to pick something wrong.
        Send-DpIntercomQuestion -RequestId 'r1' -ConversationId 'c1' -Questionnaire $script:threeQuestions

        $rows = @(@($script:sent)[-1].Keyboard.inline_keyboard)
        $rows[-1][0].text | Should -Be 'Something else - type it'
        $rows[-1][0].callback_data | Should -Be "q|$($script:DeskPilot.Intercom.PendingQuestion.token)|f"
    }

    It 'takes the words verbatim after Something else, even when they look like a number' {
        Send-DpIntercomQuestion -RequestId 'r1' -ConversationId 'c1' -Questionnaire $script:threeQuestions

        Invoke-TestTap -Choice 'f'
        $script:DeskPilot.Intercom.PendingQuestion.awaitingFreeText | Should -BeTrue
        $null = Submit-DpIntercomAnswer -Answer '2'

        # Without the verbatim flag this would have picked the second option.
        $script:DeskPilot.Intercom.PendingQuestion.questions[0].freeText | Should -Be '2'
        @($script:DeskPilot.Intercom.PendingQuestion.questions[0].selectedOptions) | Should -BeNullOrEmpty
        $script:DeskPilot.Intercom.PendingQuestion.step | Should -Be 1
    }

    It 'still honours the buttons after Something else was tapped' {
        # The nonce is deliberately left alone, so changing their mind works.
        Send-DpIntercomQuestion -RequestId 'r1' -ConversationId 'c1' -Questionnaire $script:threeQuestions

        Invoke-TestTap -Choice 'f'
        Invoke-TestTap -Choice '1'

        @($script:DeskPilot.Intercom.PendingQuestion.questions[0].selectedOptions) | Should -Be @('Spike')
        $script:DeskPilot.Intercom.PendingQuestion.step | Should -Be 1
    }

    It 'keeps what a multi-select already had when words are added to it' {
        Send-DpIntercomQuestion -RequestId 'r1' -ConversationId 'c1' -Questionnaire $script:threeQuestions
        Invoke-TestTap -Choice '0'
        $null = Submit-DpIntercomAnswer -Answer 'anything'

        Invoke-TestTap -Choice '0'                               # tick Slow
        Invoke-TestTap -Choice 'f'
        $null = Submit-DpIntercomAnswer -Answer 'licensing, probably'

        $parsed = $script:submitted | ConvertFrom-Json
        @($parsed.answers[2].selectedOptions) | Should -Be @('Slow')
        $parsed.answers[2].freeText | Should -Be 'licensing, probably'
    }
}
