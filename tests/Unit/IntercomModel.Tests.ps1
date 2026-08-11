#requires -Version 7.0

BeforeAll {
    # The module runs under Set-StrictMode -Version Latest (source/Prefix.ps1),
    # where reading a missing hashtable key is a terminating error rather than
    # $null. Tests that run without it validate different semantics than
    # production.
    Set-StrictMode -Version Latest
    $privateRoot = Join-Path $PSScriptRoot '..' '..' 'source' 'Private'
    Get-ChildItem -Path $privateRoot -Filter '*.ps1' | ForEach-Object { . $_.FullName }

    function New-TestModelState {
        [CmdletBinding()]
        [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'A test helper that builds in-memory state; it changes nothing on disk.')]
        param([string[]]$Models = @(), [string]$SettingsModel, [switch]$TurnRunning)

        $settings = Get-DpDefaultSettings
        $settings.intercom.chatId = '111'
        $settings.model = $SettingsModel

        @{
            Settings      = $settings
            Conversations = @{}
            TurnRunning   = [bool]$TurnRunning
            DataDir       = $null
            Models        = @($Models | ForEach-Object { @{ id = $_; reasoningEfforts = @() } })
            DefaultModel  = 'claude-opus-5'
            Intercom      = @{
                ConversationId = $null
                ModelIndex     = @()
                Outbound       = [System.Collections.Generic.Queue[hashtable]]::new()
                RateWindow     = [System.Collections.Generic.List[DateTime]]::new()
                Log            = [System.Collections.Generic.List[object]]::new()
                Counters       = @{ received = 0; accepted = 0; rejected = 0; sent = 0; dropped = 0; errors = 0 }
                Token          = ''
            }
        }
    }

    function Get-TestModelOutbound {
        [CmdletBinding()]
        param()
        @($script:DeskPilot.Intercom.Outbound.ToArray() | ForEach-Object { $_.text }) -join "`n"
    }

    function Add-TestBoundConversation {
        [CmdletBinding()]
        [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'A test helper that builds in-memory state; it changes nothing on disk.')]
        param([string]$Model)

        $conversation = New-DpConversation -Title 'Bound' -Model $Model
        $script:DeskPilot.Conversations[$conversation.id] = $conversation
        $script:DeskPilot.Intercom.ConversationId = $conversation.id
        $conversation
    }
}

Describe 'ConvertFrom-DpIntercomUpdate parses the model commands' -Tag 'Unit' {
    BeforeAll {
        function New-TestModelUpdate {
            [CmdletBinding()]
            [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'A test helper that builds an in-memory Telegram update; it changes nothing.')]
            param([string]$Text)

            [pscustomobject]@{
                update_id = 1
                message   = [pscustomobject]@{
                    message_id = 5
                    chat       = [pscustomobject]@{ id = '111' }
                    text       = $Text
                }
            }
        }
    }

    It 'reads each verb as its own kind' {
        (ConvertFrom-DpIntercomUpdate -Update (New-TestModelUpdate -Text '/models') -AllowedChatId '111').kind | Should -Be 'models'
        (ConvertFrom-DpIntercomUpdate -Update (New-TestModelUpdate -Text '/model 2') -AllowedChatId '111').kind | Should -Be 'model'
        (ConvertFrom-DpIntercomUpdate -Update (New-TestModelUpdate -Text '/model default') -AllowedChatId '111').kind | Should -Be 'model'
    }

    It 'carries the argument through untouched' {
        (ConvertFrom-DpIntercomUpdate -Update (New-TestModelUpdate -Text '/model  3 ') -AllowedChatId '111').text | Should -Be '3'
        (ConvertFrom-DpIntercomUpdate -Update (New-TestModelUpdate -Text '/model default') -AllowedChatId '111').text | Should -Be 'default'
    }

    It 'still rejects them from a chat that is not allow-listed' {
        $result = ConvertFrom-DpIntercomUpdate -Update (New-TestModelUpdate -Text '/model 2') -AllowedChatId '999'

        $result.kind | Should -Be 'rejected'
        $result.text | Should -BeNullOrEmpty
    }
}

Describe 'Get-DpIntercomModelList' -Tag 'Unit' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $script:DeskPilot = New-TestModelState -Models @('gpt-5-mini', 'claude-opus-5')
    }

    AfterEach { $script:DeskPilot = $null }

    It 'numbers the cached models and marks the DeskPilot default when nothing is pinned' {
        $models = @(Get-DpIntercomModelList)

        $models.Count | Should -Be 2
        $models[0].number | Should -Be 1
        $models[0].id | Should -Be 'gpt-5-mini'
        @($models | Where-Object { $_.current }).id | Should -Be 'claude-opus-5'
    }

    It 'marks the Settings model when one is set' {
        $script:DeskPilot.Settings.model = 'gpt-5-mini'

        @(Get-DpIntercomModelList | Where-Object { $_.current }).id | Should -Be 'gpt-5-mini'
    }

    It "prefers the bound Conversation's pin over the Settings default" {
        # This is Invoke-DpTurn's own order. Reporting the Setting instead would
        # name a Model the next instruction is not going to run on.
        $script:DeskPilot.Settings.model = 'claude-opus-5'
        $null = Add-TestBoundConversation -Model 'gpt-5-mini'

        @(Get-DpIntercomModelList | Where-Object { $_.current }).id | Should -Be 'gpt-5-mini'
    }

    It 'asks the Engine when the cache is empty and nothing is running' {
        $script:DeskPilot.Models = @()
        Mock Invoke-DpEngineCommand -ParameterFilter { $Command -eq 'Get-ShpModel' } -MockWith {
            @([pscustomobject]@{ Id = 'gpt-5-mini' }, [pscustomobject]@{ Id = 'claude-opus-5' })
        }

        @(Get-DpIntercomModelList).id | Should -Be @('gpt-5-mini', 'claude-opus-5')
        Should -Invoke Invoke-DpEngineCommand -Times 1 -Exactly
    }

    It 'never asks the Engine while a Turn holds the Runspace' {
        # The Engine Runspace is single-threaded, so a question asked mid-Turn
        # would park the accept thread - which is the same sentence as "the whole
        # window freezes".
        $script:DeskPilot.Models = @()
        $script:DeskPilot.TurnRunning = $true
        Mock Invoke-DpEngineCommand -MockWith { throw 'The Engine must not be called here.' }

        @(Get-DpIntercomModelList).Count | Should -Be 0
        Should -Invoke Invoke-DpEngineCommand -Times 0 -Exactly
    }

    It 'leaves the capability cache alone so a half-shaped entry never reaches a Turn' {
        $script:DeskPilot.Models = @()
        Mock Invoke-DpEngineCommand -ParameterFilter { $Command -eq 'Get-ShpModel' } -MockWith {
            @([pscustomobject]@{ Id = 'gpt-5-mini' })
        }

        $null = Get-DpIntercomModelList

        @($script:DeskPilot.Models).Count | Should -Be 0
    }

    It 'bounds how many it offers' {
        $script:DeskPilot = New-TestModelState -Models @(1..40 | ForEach-Object { "model-$_" })

        @(Get-DpIntercomModelList).Count | Should -Be 25
        @(Get-DpIntercomModelList -MaxItems 3).id | Should -Be @('model-1', 'model-2', 'model-3')
    }
}

Describe 'Intercom model navigation' -Tag 'Unit' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $script:DeskPilot = New-TestModelState -Models @('gpt-5-mini', 'claude-opus-5')
    }

    AfterEach { $script:DeskPilot = $null }

    It 'sends the list and remembers what each number meant' {
        Invoke-DpIntercomCommand -Command @{ kind = 'models'; text = ''; reason = '' }

        $script:DeskPilot.Intercom.ModelIndex | Should -Be @('gpt-5-mini', 'claude-opus-5')
        Get-TestModelOutbound | Should -Match '1\. gpt-5-mini'
        Get-TestModelOutbound | Should -Match '2\. claude-opus-5\s+<- current'
    }

    It 'says why the list is unavailable rather than freezing on the Engine' {
        $script:DeskPilot.Models = @()
        $script:DeskPilot.TurnRunning = $true

        Invoke-DpIntercomCommand -Command @{ kind = 'models'; text = ''; reason = '' }

        Get-TestModelOutbound | Should -Match 'could not list the models'
        Get-TestModelOutbound | Should -Match 'when it finishes'
    }

    It 'switches to the number the operator was shown' {
        Invoke-DpIntercomCommand -Command @{ kind = 'models'; text = ''; reason = '' }
        Invoke-DpIntercomCommand -Command @{ kind = 'model'; text = '1'; reason = '' }

        $script:DeskPilot.Settings.model | Should -Be 'gpt-5-mini'
        Get-TestModelOutbound | Should -Match 'Switched model'
    }

    It "re-pins the bound Conversation, because its pin outranks the Settings default" {
        # Writing only Settings would be a silent no-op for exactly the
        # Conversation the operator is talking to: New-DpConversation pins
        # whatever the default was when it was created.
        $conversation = Add-TestBoundConversation -Model 'claude-opus-5'
        Invoke-DpIntercomCommand -Command @{ kind = 'models'; text = ''; reason = '' }
        Invoke-DpIntercomCommand -Command @{ kind = 'model'; text = '1'; reason = '' }

        $conversation.model | Should -Be 'gpt-5-mini'
        $script:DeskPilot.Settings.model | Should -Be 'gpt-5-mini'
    }

    It 'clears both on /model default' {
        $conversation = Add-TestBoundConversation -Model 'gpt-5-mini'
        $script:DeskPilot.Settings.model = 'gpt-5-mini'

        Invoke-DpIntercomCommand -Command @{ kind = 'model'; text = 'default'; reason = '' }

        $script:DeskPilot.Settings.model | Should -BeNullOrEmpty
        $conversation.model | Should -BeNullOrEmpty
        Get-TestModelOutbound | Should -Match 'Model cleared'
        Get-TestModelOutbound | Should -Match 'claude-opus-5'
    }

    It 'refuses a number that is not on the list' {
        Invoke-DpIntercomCommand -Command @{ kind = 'models'; text = ''; reason = '' }
        Invoke-DpIntercomCommand -Command @{ kind = 'model'; text = '99'; reason = '' }

        $script:DeskPilot.Settings.model | Should -BeNullOrEmpty
        Get-TestModelOutbound | Should -Match 'no model 99'
    }

    It 'refuses something that is not a number' {
        Invoke-DpIntercomCommand -Command @{ kind = 'model'; text = 'opus'; reason = '' }

        $script:DeskPilot.Settings.model | Should -BeNullOrEmpty
        Get-TestModelOutbound | Should -Match 'not a number from the list'
    }

    It 'asks which one when /model arrives bare' {
        Invoke-DpIntercomCommand -Command @{ kind = 'model'; text = ''; reason = '' }

        Get-TestModelOutbound | Should -Match 'Send /models to see the list'
    }

    It 'needs no opted-in Project, because selecting runs nothing' {
        $script:DeskPilot.Settings.projects = @()
        $script:DeskPilot.Settings.selectedProjectId = $null

        Invoke-DpIntercomCommand -Command @{ kind = 'models'; text = ''; reason = '' }
        Invoke-DpIntercomCommand -Command @{ kind = 'model'; text = '1'; reason = '' }

        $script:DeskPilot.Settings.model | Should -Be 'gpt-5-mini'
        Get-TestModelOutbound | Should -Not -Match 'cannot do that from here'
    }

    It 'lists the model commands in /help' {
        Invoke-DpIntercomCommand -Command @{ kind = 'help'; text = ''; reason = '' }

        Get-TestModelOutbound | Should -Match '/models'
        Get-TestModelOutbound | Should -Match '/model 2'
        Get-TestModelOutbound | Should -Match '/model default'
    }
}

Describe 'Intercom model buttons' -Tag 'Unit' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $script:DeskPilot = New-TestModelState -Models @('gpt-5-mini', 'claude-opus-5')
        $script:DeskPilot.Intercom.PendingQuestion = $null
        $script:DeskPilot.Intercom.AgentIndex = @()
    }

    AfterEach { $script:DeskPilot = $null }

    It 'offers one button per model, carrying the number rather than the id' {
        Invoke-DpIntercomCommand -Command @{ kind = 'models'; text = ''; reason = '' }

        $listing = @($script:DeskPilot.Intercom.Outbound.ToArray() | Where-Object { $_.kind -eq 'models' })[0]
        $buttons = @($listing.keyboard.inline_keyboard | ForEach-Object { $_ })
        $buttons.Count | Should -Be 2
        $buttons[0].callback_data | Should -Be 'm|1'
        $buttons[1].callback_data | Should -Be 'm|2'
    }

    It 'switches on a tap' {
        Invoke-DpIntercomCommand -Command @{ kind = 'models'; text = ''; reason = '' }
        Invoke-DpIntercomCommand -Command @{ kind = 'callback'; text = 'm|1'; callbackId = 'cb1'; reason = '' }

        $script:DeskPilot.Settings.model | Should -Be 'gpt-5-mini'
    }

    It 'refuses a tap the current index no longer backs' {
        # Telegram leaves old buttons on screen forever, so a number from a listing
        # that has moved on must be refused rather than resolved against whatever
        # now sits at that position.
        Invoke-DpIntercomCommand -Command @{ kind = 'callback'; text = 'm|3'; callbackId = 'cb1'; reason = '' }

        $script:DeskPilot.Settings.model | Should -BeNullOrEmpty
        Get-TestModelOutbound | Should -Match 'That list has moved on'
    }
}

Describe 'Intercom status reports the model' -Tag 'Unit' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $script:DeskPilot = New-TestModelState -Models @('gpt-5-mini', 'claude-opus-5')
        $script:DeskPilot.Intercom.PendingQuestion = $null
        $script:DeskPilot.Intercom.QueuedPrompt = $null
        $script:DeskPilot.Intercom.LastActivityUtc = [DateTime]::UtcNow
        $script:DeskPilot.Intercom.NextCheckInUtc = $null
    }

    AfterEach { $script:DeskPilot = $null }

    It 'names the model the next Turn would run on, not the Settings field' {
        $script:DeskPilot.Settings.model = 'claude-opus-5'
        $null = Add-TestBoundConversation -Model 'gpt-5-mini'

        (Get-DpIntercomStatus).lines -join "`n" | Should -Match 'Model: gpt-5-mini'
    }
}
