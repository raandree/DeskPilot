#requires -Version 7.0

BeforeAll {
    $privateRoot = Join-Path $PSScriptRoot '..' '..' 'source' 'Private'
    Get-ChildItem -Path $privateRoot -Filter '*.ps1' | ForEach-Object { . $_.FullName }
}

Describe 'ConvertFrom-DpIntercomUpdate' -Tag 'Unit' {
    BeforeAll {
        function New-TestUpdate {
            [CmdletBinding()]
            [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'A test helper that builds an in-memory Telegram update; it changes nothing.')]
            param(
                [long]$UpdateId = 1,
                [string]$ChatId = '111',
                [string]$Text = 'hello',
                [long]$MessageId = 5,
                [long]$ReplyTo = 0
            )
            $message = [pscustomobject]@{
                message_id = $MessageId
                chat       = [pscustomobject]@{ id = $ChatId }
                text       = $Text
            }
            if ($ReplyTo -gt 0) {
                $message | Add-Member -MemberType NoteProperty -Name 'reply_to_message' -Value ([pscustomobject]@{ message_id = $ReplyTo })
            }
            [pscustomobject]@{ update_id = $UpdateId; message = $message }
        }
    }

    It 'rejects a chat that is not allow-listed' {
        $result = ConvertFrom-DpIntercomUpdate -Update (New-TestUpdate -ChatId '999' -Text '/stop') -AllowedChatId '111'

        $result.kind | Should -Be 'rejected'
        # The command must not be interpreted: the allow-list runs first.
        $result.text | Should -BeNullOrEmpty
    }

    It 'rejects everything when no chat is allow-listed' {
        $result = ConvertFrom-DpIntercomUpdate -Update (New-TestUpdate) -AllowedChatId ''

        $result.kind | Should -Be 'rejected'
    }

    It 'treats plain text as a prompt' {
        $result = ConvertFrom-DpIntercomUpdate -Update (New-TestUpdate -Text 'tidy the tests') -AllowedChatId '111'

        $result.kind | Should -Be 'prompt'
        $result.text | Should -Be 'tidy the tests'
    }

    It 'treats a reply to the pending question as the answer' {
        $update = New-TestUpdate -Text 'use the second option' -ReplyTo 42
        $result = ConvertFrom-DpIntercomUpdate -Update $update -AllowedChatId '111' -PendingQuestionMessageId 42

        $result.kind | Should -Be 'answer'
        $result.text | Should -Be 'use the second option'
    }

    It 'treats a reply to a different message as a new prompt' {
        $update = New-TestUpdate -Text 'something else' -ReplyTo 7
        $result = ConvertFrom-DpIntercomUpdate -Update $update -AllowedChatId '111' -PendingQuestionMessageId 42

        $result.kind | Should -Be 'prompt'
    }

    It 'does not accept an answer when no question is pending' {
        $update = New-TestUpdate -Text 'yes' -ReplyTo 42
        $result = ConvertFrom-DpIntercomUpdate -Update $update -AllowedChatId '111' -PendingQuestionMessageId 0

        $result.kind | Should -Be 'prompt'
    }

    It 'parses the command set' {
        $cases = @{
            '/stop'            = 'stop'
            '/status'          = 'status'
            '/help'            = 'help'
            '/new do a thing'  = 'new'
            '/steer do it now' = 'steer'
        }
        foreach ($text in $cases.Keys) {
            $result = ConvertFrom-DpIntercomUpdate -Update (New-TestUpdate -Text $text) -AllowedChatId '111'
            $result.kind | Should -Be $cases[$text]
        }
    }

    It 'carries the argument of /new and /steer' {
        $result = ConvertFrom-DpIntercomUpdate -Update (New-TestUpdate -Text '/steer  fix the build ') -AllowedChatId '111'

        $result.kind | Should -Be 'steer'
        $result.text | Should -Be 'fix the build'
    }

    It 'strips the bot mention Telegram appends in groups' {
        $result = ConvertFrom-DpIntercomUpdate -Update (New-TestUpdate -Text '/stop@my_deskpilot_bot') -AllowedChatId '111'

        $result.kind | Should -Be 'stop'
    }

    It 'reports an unknown command instead of running it as a prompt' {
        $result = ConvertFrom-DpIntercomUpdate -Update (New-TestUpdate -Text '/deploy') -AllowedChatId '111'

        $result.kind | Should -Be 'ignore'
        $result.reason | Should -Match 'Unknown command'
    }

    It 'bounds the text it carries out' {
        $long = 'a' * 9000
        $result = ConvertFrom-DpIntercomUpdate -Update (New-TestUpdate -Text $long) -AllowedChatId '111' -MaxTextLength 100

        $result.text.Length | Should -Be 100
    }

    It 'ignores an update with no message' {
        $result = ConvertFrom-DpIntercomUpdate -Update ([pscustomobject]@{ update_id = 3 }) -AllowedChatId '111'

        $result.kind | Should -Be 'ignore'
        $result.updateId | Should -Be 3
    }

    It 'ignores a null update without throwing' {
        { ConvertFrom-DpIntercomUpdate -Update $null -AllowedChatId '111' } | Should -Not -Throw
    }

    It 'still reports who sent a rejected message, so pairing can offer it' {
        $update = New-TestUpdate -ChatId '999' -Text '/start'
        $update.message | Add-Member -MemberType NoteProperty -Name 'from' -Value ([pscustomobject]@{ first_name = 'Randy'; username = 'randree3' })

        $result = ConvertFrom-DpIntercomUpdate -Update $update -AllowedChatId '111'

        $result.kind | Should -Be 'rejected'
        $result.chatId | Should -Be '999'
        $result.fromName | Should -Be 'Randy @randree3'
        $result.preview | Should -Be '/start'
        # Display-only: the command itself must still never be interpreted.
        $result.text | Should -BeNullOrEmpty
    }
}

Describe 'Intercom pairing' -Tag 'Unit' {
    BeforeEach {
        $script:DeskPilot = @{
            Settings = Get-DpDefaultSettings
            Intercom = @{
                Log     = [System.Collections.Generic.List[object]]::new()
                Token   = ''
                Pairing = @{
                    active     = $true
                    startedUtc = [DateTime]::UtcNow
                    candidates = [System.Collections.Generic.List[object]]::new()
                }
            }
        }
        $script:candidate = @{ chatId = '999'; fromName = 'Randy @randree3'; preview = '/start'; kind = 'rejected' }
    }

    AfterEach { $script:DeskPilot = $null }

    It 'keeps a chat that messaged the bot while pairing is open' {
        Add-DpIntercomPairingCandidate -Command $script:candidate

        $script:DeskPilot.Intercom.Pairing.candidates.Count | Should -Be 1
        $script:DeskPilot.Intercom.Pairing.candidates[0].chatId | Should -Be '999'
        $script:DeskPilot.Intercom.Pairing.candidates[0].fromName | Should -Be 'Randy @randree3'
    }

    It 'does not duplicate a chat that sends several messages' {
        Add-DpIntercomPairingCandidate -Command $script:candidate
        Add-DpIntercomPairingCandidate -Command @{ chatId = '999'; fromName = 'Randy'; preview = 'hello?'; kind = 'rejected' }

        $script:DeskPilot.Intercom.Pairing.candidates.Count | Should -Be 1
        $script:DeskPilot.Intercom.Pairing.candidates[0].preview | Should -Be 'hello?'
    }

    It 'bounds the candidate list so a flood cannot bury the real one' {
        1..10 | ForEach-Object { Add-DpIntercomPairingCandidate -Command @{ chatId = "chat$_"; fromName = 'X'; preview = 'y'; kind = 'rejected' } }

        $script:DeskPilot.Intercom.Pairing.candidates.Count | Should -Be 5
    }

    It 'records nothing when pairing is not open' {
        $script:DeskPilot.Intercom.Pairing.active = $false

        Add-DpIntercomPairingCandidate -Command $script:candidate

        $script:DeskPilot.Intercom.Pairing.candidates.Count | Should -Be 0
    }

    It 'never adopts a candidate on its own' {
        Add-DpIntercomPairingCandidate -Command $script:candidate

        # Adoption stays an explicit click at the machine; pairing only observes.
        $script:DeskPilot.Settings.intercom.chatId | Should -BeNullOrEmpty
    }
}

Describe 'Format-DpIntercomMessage' -Tag 'Unit' {
    It 'composes a title and fact lines into one chunk' {
        $parts = @(Format-DpIntercomMessage -Title 'Done.' -Line @('Conversation: Notes', 'Took: 12 s'))

        $parts.Count | Should -Be 1
        $parts[0] | Should -Be "Done.`nConversation: Notes`nTook: 12 s"
    }

    It 'drops empty fact lines' {
        $parts = @(Format-DpIntercomMessage -Title 'Done.' -Line @('kept', '', '   '))

        $parts[0] | Should -Be "Done.`nkept"
    }

    It 'splits a long body and numbers every part' {
        $body = (1..400 | ForEach-Object { "line $_ with enough text to push past the limit" }) -join "`n"
        $parts = @(Format-DpIntercomMessage -Title 'Done.' -Body $body)

        $parts.Count | Should -BeGreaterThan 1
        foreach ($part in $parts) { $part.Length | Should -BeLessOrEqual 4096 }
        $parts[0] | Should -Match '\(1/\d+\)$'
        $parts[-1] | Should -Match "\($($parts.Count)/$($parts.Count)\)$"
    }

    It 'truncates a body beyond the overall cap' {
        $parts = @(Format-DpIntercomMessage -Title 'Done.' -Body ('x' * 5000) -MaxTotalLength 200)

        ($parts -join '') | Should -Match 'truncated'
    }
}

Describe 'Test-DpIntercomProject' -Tag 'Unit' {
    It 'refuses when no Project is open' {
        $decision = Test-DpIntercomProject -Settings @{ selectedProjectId = $null; projects = @() }

        $decision.allowed | Should -BeFalse
        $decision.reason | Should -Match 'No project is open'
    }

    It 'refuses a Project that has not opted in, and names it' {
        $settings = @{
            selectedProjectId = 'p1'
            projects          = @(@{ id = 'p1'; name = 'Accounts'; path = 'C:\a'; intercom = $false })
        }

        $decision = Test-DpIntercomProject -Settings $settings

        $decision.allowed | Should -BeFalse
        $decision.reason | Should -Match 'Accounts'
    }

    It 'allows a Project that has opted in' {
        $settings = @{
            selectedProjectId = 'p1'
            projects          = @(@{ id = 'p1'; name = 'Notes'; path = 'C:\a'; intercom = $true })
        }

        (Test-DpIntercomProject -Settings $settings).allowed | Should -BeTrue
    }

    It 'refuses when the selected Project is no longer registered' {
        $decision = Test-DpIntercomProject -Settings @{ selectedProjectId = 'gone'; projects = @() }

        $decision.allowed | Should -BeFalse
    }
}

Describe 'Intercom Settings validation' -Tag 'Unit' {
    BeforeEach {
        $script:current = Get-DpDefaultSettings
    }

    It 'defaults to off with no chat and no token' {
        $script:current.intercom.enabled | Should -BeFalse
        $script:current.intercom.chatId | Should -BeNullOrEmpty
        $script:current.ContainsKey('botToken') | Should -BeFalse
    }

    It 'accepts a valid patch' {
        $merged = Merge-DpSettings -Current $script:current -Patch @{ intercom = @{ enabled = $true; chatId = '-1001234567'; heartbeatMinutes = 10 } }

        $merged.intercom.enabled | Should -BeTrue
        $merged.intercom.chatId | Should -Be '-1001234567'
        $merged.intercom.heartbeatMinutes | Should -Be 10
        # Untouched keys keep their previous values.
        $merged.intercom.maxMessagesPerHour | Should -Be 60
    }

    It 'rejects a chat id that is not a Telegram id' {
        { Merge-DpSettings -Current $script:current -Patch @{ intercom = @{ chatId = 'me@example.com' } } } |
            Should -Throw -ExpectedMessage '*chatId*'
    }

    It 'rejects an out-of-range interval' {
        { Merge-DpSettings -Current $script:current -Patch @{ intercom = @{ heartbeatMinutes = 0 } } } |
            Should -Throw -ExpectedMessage '*between 1 and 1440*'
    }

    It 'rejects an unknown intercom setting' {
        { Merge-DpSettings -Current $script:current -Patch @{ intercom = @{ webhook = 'https://example.com' } } } |
            Should -Throw -ExpectedMessage "*Unknown intercom setting*"
    }

    It 'refuses to store the bot token as a Setting' {
        { Merge-DpSettings -Current $script:current -Patch @{ intercom = @{ botToken = '123456789:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' } } } |
            Should -Throw -ExpectedMessage '*not a setting*'
    }

    It 'does not mutate the settings it was given' {
        $null = Merge-DpSettings -Current $script:current -Patch @{ intercom = @{ enabled = $true } }

        $script:current.intercom.enabled | Should -BeFalse
    }

    It 'carries the per-Project remote-control flag through normalisation' {
        $project = ConvertTo-DpProject -InputObject ([pscustomobject]@{ id = 'p1'; name = 'N'; path = 'C:\a'; intercom = $true })

        $project.intercom | Should -BeTrue
    }

    It 'defaults a Project to no remote control' {
        $project = ConvertTo-DpProject -InputObject ([pscustomobject]@{ path = 'C:\a' })

        $project.intercom | Should -BeFalse
    }
}

Describe 'Hide-DpIntercomSecret' -Tag 'Unit' {
    It 'removes anything shaped like a bot token' {
        $text = 'Connection failed for https://api.telegram.org/bot123456789:AAHqWeRtYuIoPaSdFgHjKlZxCvBnM12/getUpdates'

        $redacted = Hide-DpIntercomSecret -Text $text

        $redacted | Should -Not -Match '123456789:'
        $redacted | Should -Match '<token>'
    }

    It 'returns an empty string for no input' {
        Hide-DpIntercomSecret -Text $null | Should -Be ''
    }
}

Describe 'Send-DpIntercomMessage' -Tag 'Unit' {
    BeforeEach {
        $script:DeskPilot = @{
            Settings = @{ intercom = @{ maxMessagesPerHour = 2; chatId = '111' } }
            Intercom = @{
                Outbound    = [System.Collections.Generic.Queue[hashtable]]::new()
                RateWindow  = [System.Collections.Generic.List[DateTime]]::new()
                Log         = [System.Collections.Generic.List[object]]::new()
                Counters    = @{ received = 0; accepted = 0; rejected = 0; sent = 0; dropped = 0; errors = 0 }
                Token       = ''
            }
        }
    }

    AfterEach { $script:DeskPilot = $null }

    It 'queues a message and records it against the hourly cap' {
        Send-DpIntercomMessage -Title 'Done.' -Kind 'done' | Should -BeTrue

        $script:DeskPilot.Intercom.Outbound.Count | Should -Be 1
        $script:DeskPilot.Intercom.RateWindow.Count | Should -Be 1
    }

    It 'drops a message once the hourly cap is reached' {
        $null = Send-DpIntercomMessage -Title 'One' -Kind 'notice'
        $null = Send-DpIntercomMessage -Title 'Two' -Kind 'notice'

        Send-DpIntercomMessage -Title 'Three' -Kind 'notice' | Should -BeFalse
        $script:DeskPilot.Intercom.Counters.dropped | Should -Be 1
        $script:DeskPilot.Intercom.Outbound.Count | Should -Be 2
    }

    It 'exempts the live status message from the cap so death stays detectable' {
        $null = Send-DpIntercomMessage -Title 'One' -Kind 'notice'
        $null = Send-DpIntercomMessage -Title 'Two' -Kind 'notice'

        Send-DpIntercomMessage -Title 'Status' -Kind 'status' -Capture 'status' | Should -BeTrue
        $script:DeskPilot.Intercom.Counters.dropped | Should -Be 0
    }

    It 'marks only the first part of a split message with the capture' {
        $body = (1..400 | ForEach-Object { "line $_ with enough text to push past the message limit" }) -join "`n"
        $null = Send-DpIntercomMessage -Title 'The agent needs your input' -Body $body -Kind 'question' -Capture 'question'

        $parts = @($script:DeskPilot.Intercom.Outbound.ToArray())
        $parts.Count | Should -BeGreaterThan 1
        $parts[0].capture | Should -Be 'question'
        $parts[1].capture | Should -Be ''
    }

    It 'refuses to queue anything before a phone is linked' {
        $script:DeskPilot.Settings.intercom.chatId = $null

        Send-DpIntercomMessage -Title 'Done.' -Kind 'done' | Should -BeFalse
        $script:DeskPilot.Intercom.Outbound.Count | Should -Be 0
    }
}

Describe 'Get-DpIntercomPayload' -Tag 'Unit' {
    BeforeEach {
        $settings = Get-DpDefaultSettings
        $settings.intercom.enabled = $true
        $settings.intercom.chatId = '111'
        $script:DeskPilot = @{
            Settings      = $settings
            Conversations = @{}
            Intercom      = @{
                TokenConfigured = $true
                Token           = '123456789:AAHqWeRtYuIoPaSdFgHjKlZxCvBnM12'
                Running         = $true
                LastError       = ''
                PendingQuestion = $null
                QueuedPrompt    = $null
                LastPollUtc     = $null
                NextCheckInUtc  = $null
                Counters        = @{ received = 4; accepted = 3; rejected = 1; sent = 9; dropped = 0; errors = 0 }
                Log             = [System.Collections.Generic.List[object]]::new()
                Pairing         = @{ active = $false; startedUtc = $null; candidates = [System.Collections.Generic.List[object]]::new() }
            }
        }
    }

    AfterEach { $script:DeskPilot = $null }

    It 'never returns the bot token' {
        $payload = Get-DpIntercomPayload

        ($payload | ConvertTo-Json -Depth 6) | Should -Not -Match '123456789:'
        $payload.tokenConfigured | Should -BeTrue
    }

    It 'reports the rejection count so a probe is visible' {
        (Get-DpIntercomPayload).counters.rejected | Should -Be 1
    }

    It 'reports needs-token when no token is stored' {
        $script:DeskPilot.Intercom.TokenConfigured = $false

        (Get-DpIntercomPayload).status | Should -Be 'needs-token'
    }

    It 'reports off when the switch is off' {
        $script:DeskPilot.Settings.intercom.enabled = $false

        (Get-DpIntercomPayload).status | Should -Be 'off'
    }

    It 'reports needs-chat when no phone is linked and pairing is closed' {
        $script:DeskPilot.Settings.intercom.chatId = $null

        (Get-DpIntercomPayload).status | Should -Be 'needs-chat'
    }

    It 'reports pairing while the link window is open' {
        $script:DeskPilot.Settings.intercom.chatId = $null
        $script:DeskPilot.Intercom.Pairing.active = $true
        $script:DeskPilot.Intercom.Pairing.startedUtc = [DateTime]::UtcNow

        $payload = Get-DpIntercomPayload

        $payload.status | Should -Be 'pairing'
        $payload.pairing.active | Should -BeTrue
        $payload.pairing.expiresUtc | Should -Not -BeNullOrEmpty
    }
}

Describe 'Intercom secret store' -Tag 'Unit' {
    BeforeEach {
        $script:dataDir = Join-Path $TestDrive ('ic-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:dataDir | Out-Null
    }

    It 'round-trips the bot token' {
        Save-DpIntercomSecret -Token '123456789:AAHqWeRtYuIoPaSdFgHjKlZxCvBnM12' -Directory $script:dataDir -Confirm:$false |
            Should -BeTrue

        Read-DpIntercomSecret -Directory $script:dataDir | Should -Be '123456789:AAHqWeRtYuIoPaSdFgHjKlZxCvBnM12'
    }

    It 'never writes the token in clear text' {
        $null = Save-DpIntercomSecret -Token '123456789:AAHqWeRtYuIoPaSdFgHjKlZxCvBnM12' -Directory $script:dataDir -Confirm:$false

        $raw = Get-Content -LiteralPath (Join-Path $script:dataDir 'intercom.secret') -Raw
        $raw | Should -Not -Match 'AAHqWeRtYuIoPaSdFgHjKlZxCvBnM12'
    }

    It 'keeps the token out of settings.json entirely' {
        $null = Save-DpIntercomSecret -Token '123456789:AAHqWeRtYuIoPaSdFgHjKlZxCvBnM12' -Directory $script:dataDir -Confirm:$false
        $settings = Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch @{ intercom = @{ enabled = $true; chatId = '111' } }
        Save-DpSettings -Settings $settings -Directory $script:dataDir

        $raw = Get-Content -LiteralPath (Join-Path $script:dataDir 'settings.json') -Raw
        $raw | Should -Not -Match '123456789'
        $raw | Should -Match '"chatId"'
    }

    It 'removes the stored token when given an empty value' {
        $null = Save-DpIntercomSecret -Token '123456789:AAHqWeRtYuIoPaSdFgHjKlZxCvBnM12' -Directory $script:dataDir -Confirm:$false

        Save-DpIntercomSecret -Token '' -Directory $script:dataDir -Confirm:$false | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:dataDir 'intercom.secret') | Should -BeFalse
        Read-DpIntercomSecret -Directory $script:dataDir | Should -Be ''
    }

    It 'reports no token when none was ever stored' {
        Read-DpIntercomSecret -Directory $script:dataDir | Should -Be ''
    }

    It 'survives a corrupt secret file instead of throwing' {
        Set-Content -LiteralPath (Join-Path $script:dataDir 'intercom.secret') -Value 'not json'

        Read-DpIntercomSecret -Directory $script:dataDir | Should -Be ''
    }
}

Describe 'Update-DpIntercomState' -Tag 'Unit' {
    BeforeEach {
        $script:dataDir = Join-Path $TestDrive ('pump-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:dataDir | Out-Null
        $script:DeskPilot = @{
            Settings      = Get-DpDefaultSettings
            Conversations = @{}
            TurnRunning   = $false
            DataDir       = $script:dataDir
            Intercom      = Initialize-DpIntercom -Directory $script:dataDir
        }
    }

    AfterEach {
        if ($script:DeskPilot.Intercom.Client) { $script:DeskPilot.Intercom.Client.Dispose() }
        $script:DeskPilot = $null
    }

    It 'does nothing and contacts nothing while Intercom is off' {
        { Update-DpIntercomState } | Should -Not -Throw

        $script:DeskPilot.Intercom.Running | Should -BeFalse
        $script:DeskPilot.Intercom.PollTask | Should -BeNullOrEmpty
        $script:DeskPilot.Intercom.Outbound.Count | Should -Be 0
    }

    It 'stays off when enabled but no token is stored' {
        $script:DeskPilot.Settings.intercom.enabled = $true
        $script:DeskPilot.Settings.intercom.chatId = '111'

        { Update-DpIntercomState } | Should -Not -Throw

        $script:DeskPilot.Intercom.Running | Should -BeFalse
    }

    It 'stays off when a token is stored but no chat is allow-listed' {
        $script:DeskPilot.Settings.intercom.enabled = $true
        $script:DeskPilot.Intercom.TokenConfigured = $true
        $script:DeskPilot.Intercom.Token = '123456789:AAHqWeRtYuIoPaSdFgHjKlZxCvBnM12'

        { Update-DpIntercomState } | Should -Not -Throw

        $script:DeskPilot.Intercom.Running | Should -BeFalse
    }

    It 'never starts a Turn without -AllowTurn, even with a prompt queued' {
        $script:DeskPilot.Intercom.QueuedPrompt = 'do the thing'
        Mock Invoke-DpIntercomTurn { throw 'A Turn must never start from the in-Turn pump.' }

        { Update-DpIntercomState } | Should -Not -Throw

        Should -Invoke Invoke-DpIntercomTurn -Times 0
        $script:DeskPilot.Intercom.QueuedPrompt | Should -Be 'do the thing'
    }
}
