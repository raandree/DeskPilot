#requires -Version 7.0

# The seven findings of the 2026-09-02 security review of Intercom group chat
# (`ee0bdd7`). Every Describe here asserts a refusal, and pairs it with a case
# proving the allowed branch is still reached - a refusal test that passes
# because the code never got that far is worse than no test at all.

BeforeAll {
    # The module runs under Set-StrictMode -Version Latest (source/Prefix.ps1),
    # where reading a missing hashtable key is a terminating error rather than
    # $null. Tests that run without it validate different semantics than
    # production.
    Set-StrictMode -Version Latest
    $privateRoot = Join-Path $PSScriptRoot '..' '..' 'source' 'Private'
    Get-ChildItem -Path $privateRoot -Filter '*.ps1' | ForEach-Object { . $_.FullName }

    $script:GroupChat = '-1004455397827'
    $script:OwnChat = '111'

    function New-TestAuthorityState {
        [CmdletBinding()]
        [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'A test helper that builds in-memory state; it changes nothing on disk.')]
        param(
            [switch]$GroupAllowed,
            [switch]$ProjectRemote,
            [switch]$ProjectGroup
        )

        $settings = Get-DpDefaultSettings
        $settings.intercom.chatId = '111'
        $settings.intercom.allowGroupChat = [bool]$GroupAllowed
        $settings.intercom.groupChatIds = @(if ($GroupAllowed) { '-1004455397827' } else { })
        $settings.projects = @(
            @{
                id            = 'p1'
                name          = 'Notes'
                path          = 'C:\Git\Notes'
                intercom      = [bool]$ProjectRemote
                intercomGroup = [bool]$ProjectGroup
            }
        )
        $settings.selectedProjectId = 'p1'
        $settings.workspaceFolder = 'C:\Git\Notes'

        @{
            Settings              = $settings
            Conversations         = @{}
            Changes               = @{}
            TurnRunning           = $false
            CancelRequested       = $false
            DataDir               = $null
            ConversationsRevision = 0
            Engine                = @{ UserPromptBridge = $null }
            Intercom              = @{
                ConversationId  = $null
                ChatIndex       = @()
                AgentIndex      = @()
                ModelIndex      = @()
                ProjectIndex    = @()
                PendingQuestion = $null
                QueuedPrompt    = $null
                QueuedChatId    = $null
                QueuedImage     = $null
                ReplyChatId     = $null
                Download        = @{
                    stage = ''; task = $null; fileId = ''; fileName = ''
                    mimeType = ''; isImage = $false; caption = ''; chatId = ''; startedUtc = $null
                }
                Outbound        = [System.Collections.Generic.Queue[hashtable]]::new()
                RateWindow      = [System.Collections.Generic.List[DateTime]]::new()
                Log             = [System.Collections.Generic.List[object]]::new()
                Counters        = @{ received = 0; accepted = 0; rejected = 0; sent = 0; dropped = 0; errors = 0 }
                Token           = ''
            }
        }
    }

    function New-TestCommand {
        [CmdletBinding()]
        [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'A test helper that builds an in-memory command record; it changes nothing.')]
        param(
            [Parameter(Mandatory)][string]$Kind,
            [string]$Text = '',
            [string]$ChatId = '111',
            [string]$FromName = 'Sam @sam'
        )

        @{
            updateId = 1; kind = $Kind; text = $Text; chatId = $ChatId; messageId = 5
            replyToMessageId = 0; reason = ''; fromName = $FromName; preview = $Text
            attachment = $null; callbackId = ''
        }
    }

    function Get-TestOutboundText {
        [CmdletBinding()]
        param()
        @($script:DeskPilot.Intercom.Outbound.ToArray() | ForEach-Object { $_.text }) -join "`n"
    }
}

Describe 'Test-DpIntercomChat' -Tag 'Unit' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $script:DeskPilot = New-TestAuthorityState -GroupAllowed
    }

    AfterEach { $script:DeskPilot = $null }

    It 'knows the operator from the group' {
        $own = Test-DpIntercomChat -ChatId $script:OwnChat
        $group = Test-DpIntercomChat -ChatId $script:GroupChat

        $own.allowed | Should -BeTrue
        $own.group | Should -BeFalse
        $group.allowed | Should -BeTrue
        $group.group | Should -BeTrue
    }

    It 'reads no chat as the operator, which is what a locally started turn carries' {
        $decision = Test-DpIntercomChat -ChatId ''

        $decision.allowed | Should -BeTrue
        $decision.group | Should -BeFalse
    }

    It 'refuses a stranger, and calls it a group so the narrowest authority applies' {
        $decision = Test-DpIntercomChat -ChatId '-1009999999999'

        $decision.allowed | Should -BeFalse
        $decision.group | Should -BeTrue
    }

    It 'holds the group inert while the switch is off, even with the id still stored' {
        $script:DeskPilot.Settings.intercom.allowGroupChat = $false

        (Test-DpIntercomChat -ChatId $script:GroupChat).allowed | Should -BeFalse
    }
}

Describe 'FIND-002 - a project opted in for the phone is not thereby opted in for the group' -Tag 'Unit' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $script:DeskPilot = New-TestAuthorityState -GroupAllowed -ProjectRemote
    }

    AfterEach { $script:DeskPilot = $null }

    It 'refuses a group command in a project shared only with the operator' {
        # The flag was ticked when the operator was the only possible caller.
        # Allow-listing a group must not re-scope it retroactively.
        $decision = Test-DpIntercomProject -Settings $script:DeskPilot.Settings -OriginChatId $script:GroupChat

        $decision.allowed | Should -BeFalse
        $decision.reason | Should -Match 'not shared with group chats'
    }

    It 'allows the same project for the operator, so the first flag still means something' {
        $decision = Test-DpIntercomProject -Settings $script:DeskPilot.Settings -OriginChatId $script:OwnChat

        $decision.allowed | Should -BeTrue
        $decision.reason | Should -BeNullOrEmpty
    }

    It 'allows the group once the project is shared with groups too' {
        $script:DeskPilot.Settings.projects[0].intercomGroup = $true

        (Test-DpIntercomProject -Settings $script:DeskPilot.Settings -OriginChatId $script:GroupChat).allowed | Should -BeTrue
    }

    It 'still refuses the group when only the group flag is set and phone control is off' {
        $script:DeskPilot.Settings.projects[0].intercom = $false
        $script:DeskPilot.Settings.projects[0].intercomGroup = $true

        $decision = Test-DpIntercomProject -Settings $script:DeskPilot.Settings -OriginChatId $script:GroupChat

        $decision.allowed | Should -BeFalse
        $decision.reason | Should -Match 'allow phone control'
    }

    It 'queues no work for a group prompt in a project it is not shared with' {
        Invoke-DpIntercomCommand -Command (New-TestCommand -Kind 'prompt' -Text 'push it' -ChatId $script:GroupChat)

        $script:DeskPilot.Intercom.QueuedPrompt | Should -BeNullOrEmpty
        Get-TestOutboundText | Should -Match 'not shared with group chats'
    }

    It 'queues the same prompt from the group once the project is shared' {
        $script:DeskPilot.Settings.projects[0].intercomGroup = $true

        Invoke-DpIntercomCommand -Command (New-TestCommand -Kind 'prompt' -Text 'push it' -ChatId $script:GroupChat)

        $script:DeskPilot.Intercom.QueuedPrompt | Should -Be 'push it'
        $script:DeskPilot.Intercom.QueuedChatId | Should -Be $script:GroupChat
    }

    It 'defaults an existing project with no group flag to off rather than throwing' {
        # A settings.json written before the flag existed must migrate to the safe
        # value, not to a StrictMode missing-key error on the authority path.
        $script:DeskPilot.Settings.projects = @([pscustomobject]@{ id = 'p1'; name = 'Notes'; path = 'C:\Git\Notes'; intercom = $true })

        (Test-DpIntercomProject -Settings $script:DeskPilot.Settings -OriginChatId $script:GroupChat).allowed | Should -BeFalse
        (Test-DpIntercomProject -Settings $script:DeskPilot.Settings -OriginChatId $script:OwnChat).allowed | Should -BeTrue
    }

    It 'normalises both flags off for a project that carries neither' {
        $project = ConvertTo-DpProject -InputObject @{ path = 'C:\Git\Notes' }

        $project.intercom | Should -BeFalse
        $project.intercomGroup | Should -BeFalse
    }
}

Describe 'FIND-002 - switching group access on names the projects it covers' -Tag 'Unit' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $script:dataDir = Join-Path $TestDrive ('grp-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:dataDir | Out-Null
        $script:DeskPilot = New-TestAuthorityState -ProjectRemote -ProjectGroup
        $script:DeskPilot.Intercom = Initialize-DpIntercom -Directory $script:dataDir
        $script:DeskPilot.Intercom.TokenConfigured = $true
        $script:responseStream = [System.IO.MemoryStream]::new()
        # The pump would reach the network; the route's own behaviour is the subject.
        Mock Update-DpIntercomState { }
    }

    AfterEach {
        if ($script:DeskPilot.Intercom.Client) { $script:DeskPilot.Intercom.Client.Dispose() }
        $script:responseStream.Dispose()
        $script:DeskPilot = $null
    }

    It 'refuses the grant until the covered projects have been disclosed' {
        Invoke-DpRouteHandler -Name 'putIntercom' -Stream $script:responseStream -Body ([pscustomobject]@{ allowGroupChat = $true })

        $response = [System.Text.Encoding]::UTF8.GetString($script:responseStream.ToArray())
        $response | Should -Match '^HTTP/1\.1 409'
        $payload = ($response -split "`r`n`r`n", 2)[1] | ConvertFrom-Json
        $payload.error.code | Should -Be 'confirm_group_projects'
        $payload.error.projects | Should -Contain 'Notes'
        # And the grant was not made.
        $script:DeskPilot.Settings.intercom.allowGroupChat | Should -BeFalse
    }

    It 'makes the grant once the disclosure is answered' {
        $body = [pscustomobject]@{ allowGroupChat = $true; confirmGroupProjects = $true }

        Invoke-DpRouteHandler -Name 'putIntercom' -Stream $script:responseStream -Body $body

        [System.Text.Encoding]::UTF8.GetString($script:responseStream.ToArray()) | Should -Match '^HTTP/1\.1 200'
        $script:DeskPilot.Settings.intercom.allowGroupChat | Should -BeTrue
    }

    It 'asks nothing when no project is shared with groups yet' {
        $script:DeskPilot.Settings.projects[0].intercomGroup = $false

        Invoke-DpRouteHandler -Name 'putIntercom' -Stream $script:responseStream -Body ([pscustomobject]@{ allowGroupChat = $true })

        [System.Text.Encoding]::UTF8.GetString($script:responseStream.ToArray()) | Should -Match '^HTTP/1\.1 200'
        $script:DeskPilot.Settings.intercom.allowGroupChat | Should -BeTrue
    }
}

Describe 'FIND-001 - /delete and /undo belong to the operator' -Tag 'Unit' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $script:DeskPilot = New-TestAuthorityState -GroupAllowed -ProjectRemote -ProjectGroup
        $script:DeskPilot.Conversations = @{
            c1 = @{
                id = 'c1'; title = 'Ledger'; archived = $false; pinned = $false
                updatedUtc = [DateTime]::UtcNow.ToString('o')
                messages = @(@{ id = 'm1'; role = 'user'; content = 'do it'; checkpoint = @{ sha = 'abc123' } })
            }
        }
        $script:DeskPilot.Intercom.ConversationId = 'c1'
        $script:DeskPilot.Intercom.ChatIndex = @('c1')
        # The restore itself is not the subject; whether it is reached at all is.
        Mock Restore-DpCheckpoint { @{ ok = $true; restored = @(); removed = @(); prompt = 'do it' } }
    }

    AfterEach { $script:DeskPilot = $null }

    It 'refuses /delete from a group, even in a project the group may work in' {
        Invoke-DpIntercomCommand -Command (New-TestCommand -Kind 'delete' -Text '1 confirm' -ChatId $script:GroupChat)

        $script:DeskPilot.Conversations.ContainsKey('c1') | Should -BeTrue
        Get-TestOutboundText | Should -Match 'Not from a group chat'
    }

    It 'deletes for the operator, so the refusal is not just an unreachable branch' {
        Invoke-DpIntercomCommand -Command (New-TestCommand -Kind 'delete' -Text '1 confirm' -ChatId $script:OwnChat)

        $script:DeskPilot.Conversations.ContainsKey('c1') | Should -BeFalse
    }

    It 'refuses /undo from a group without touching a single file' {
        Invoke-DpIntercomCommand -Command (New-TestCommand -Kind 'undo' -Text 'confirm' -ChatId $script:GroupChat)

        Should -Invoke Restore-DpCheckpoint -Times 0 -Exactly
        Get-TestOutboundText | Should -Match 'Not from a group chat'
    }

    It 'restores for the operator, so the refusal is not just an unreachable branch' {
        Invoke-DpIntercomCommand -Command (New-TestCommand -Kind 'undo' -Text 'confirm' -ChatId $script:OwnChat)

        Should -Invoke Restore-DpCheckpoint -Times 1 -Exactly
        Get-TestOutboundText | Should -Match 'Undone'
    }

    It 'gates the restore inside Restore-DpIntercomCheckpoint, not only at the dispatcher' {
        # A second caller added later must not reach the file rewrite by skipping
        # the command switch.
        Restore-DpIntercomCheckpoint -Confirmed -OriginChatId $script:GroupChat

        Should -Invoke Restore-DpCheckpoint -Times 0 -Exactly
    }

    It 'leaves /archive open to the group, because /unarchive undoes it' {
        Invoke-DpIntercomCommand -Command (New-TestCommand -Kind 'archive' -Text '1' -ChatId $script:GroupChat)

        $script:DeskPilot.Conversations['c1'].archived | Should -BeTrue
    }
}

Describe 'FIND-003 - the audit log attributes an action to a chat and a sender' -Tag 'Unit' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $script:DeskPilot = New-TestAuthorityState -GroupAllowed -ProjectRemote -ProjectGroup
    }

    AfterEach { $script:DeskPilot = $null }

    It 'records who sent an accepted command' {
        Invoke-DpIntercomCommand -Command (New-TestCommand -Kind 'prompt' -Text 'ship it' -ChatId $script:GroupChat -FromName 'Mo @mo')

        $entry = @($script:DeskPilot.Intercom.Log)[0]
        $entry.kind | Should -Be 'prompt'
        $entry.chatId | Should -Be $script:GroupChat
        $entry.from | Should -Be 'Mo @mo'
    }

    It 'records who was rejected, which is the line an attack shows up on' {
        $rejected = New-TestCommand -Kind 'rejected' -ChatId '-1009999999999' -FromName 'Nobody'
        $rejected.reason = "Message from chat '-1009999999999' is not allow-listed."

        Invoke-DpIntercomCommand -Command $rejected

        $entry = @($script:DeskPilot.Intercom.Log)[0]
        $entry.accepted | Should -BeFalse
        $entry.chatId | Should -Be '-1009999999999'
        $entry.from | Should -Be 'Nobody'
    }

    It 'leaves the fields empty rather than absent when there is no sender' {
        # The Settings panel reads them on every row, so an outbound or system
        # line must carry the keys too.
        Add-DpIntercomLog -Direction 'system' -Kind 'enabled' -Detail 'Intercom is on.'

        $entry = @($script:DeskPilot.Intercom.Log)[0]
        $entry.chatId | Should -Be ''
        $entry.from | Should -Be ''
    }

    It 'redacts and bounds the sender name, which is whatever Telegram was told' {
        Add-DpIntercomLog -Direction 'in' -Kind 'prompt' -From ('x' * 200) -ChatId '111'

        @($script:DeskPilot.Intercom.Log)[0].from.Length | Should -Be 60
    }

    It 'carries the attribution out through the API projection' {
        $script:DeskPilot.Intercom.TokenConfigured = $true
        $script:DeskPilot.Intercom.Running = $true
        $script:DeskPilot.Intercom.LastError = ''
        $script:DeskPilot.Intercom.LastPollUtc = $null
        $script:DeskPilot.Intercom.NextCheckInUtc = $null
        $script:DeskPilot.Intercom.Pairing = @{ active = $false; startedUtc = $null; candidates = [System.Collections.Generic.List[object]]::new() }
        $script:DeskPilot.Intercom.RemoteTurn = @{ active = $false; conversationId = $null; prompt = ''; startedUtc = $null; text = ''; reasoning = '' }
        Add-DpIntercomLog -Direction 'in' -Kind 'undo' -Detail 'confirm' -ChatId $script:GroupChat -From 'Mo @mo'

        $payload = Get-DpIntercomPayload

        @($payload.log)[-1].from | Should -Be 'Mo @mo'
        @($payload.log)[-1].chatId | Should -Be $script:GroupChat
    }
}

Describe 'FIND-004 and FIND-005 - the addressing layer re-validates its target' -Tag 'Unit' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $script:DeskPilot = New-TestAuthorityState -GroupAllowed -ProjectRemote -ProjectGroup
    }

    AfterEach { $script:DeskPilot = $null }

    It 'sends to the group while the group is still allow-listed' {
        $script:DeskPilot.Intercom.ReplyChatId = $script:GroupChat

        $null = Send-DpIntercomMessage -Title 'Done.' -Kind 'done'

        @($script:DeskPilot.Intercom.Outbound.ToArray())[0].chatId | Should -Be $script:GroupChat
    }

    It 'never answers a chat that has lost its authority, whatever left the id behind' {
        # The reply target is stamped before a message is classified and outlives a
        # tick in three carriers, so this cannot rest on any one early return.
        $script:DeskPilot.Intercom.ReplyChatId = $script:GroupChat
        $script:DeskPilot.Settings.intercom.allowGroupChat = $false

        $null = Send-DpIntercomMessage -Title 'Done.' -Kind 'done'

        @($script:DeskPilot.Intercom.Outbound.ToArray())[0].chatId | Should -Be $script:OwnChat
        $script:DeskPilot.Intercom.Counters.dropped | Should -Be 1
        @($script:DeskPilot.Intercom.Log | Where-Object { $_.kind -eq 'misrouted' }).Count | Should -Be 1
    }

    It 'never answers a chat that was never allow-listed at all' {
        $script:DeskPilot.Intercom.ReplyChatId = '-1009999999999'

        $null = Send-DpIntercomMessage -Title 'Got it.' -Kind 'ack'

        @($script:DeskPilot.Intercom.Outbound.ToArray())[0].chatId | Should -Be $script:OwnChat
    }

    It 'keeps the live status message on the operator chat regardless' {
        $script:DeskPilot.Intercom.ReplyChatId = $script:GroupChat

        $null = Send-DpIntercomMessage -Title 'Status' -Kind 'status' -Capture 'status'

        @($script:DeskPilot.Intercom.Outbound.ToArray())[0].chatId | Should -Be $script:OwnChat
        $script:DeskPilot.Intercom.Counters.dropped | Should -Be 0
    }

    It 'abandons an in-flight attachment fetch bound to a chat that was dropped' {
        $script:DeskPilot.Intercom.Download.stage = 'lookup'
        $script:DeskPilot.Intercom.Download.chatId = $script:GroupChat
        $script:DeskPilot.Intercom.Download.fileName = 'plan.docx'

        Clear-DpIntercomDownload

        $script:DeskPilot.Intercom.Download.stage | Should -Be ''
        $script:DeskPilot.Intercom.Download.chatId | Should -Be ''
    }
}

Describe 'FIND-004 - de-authorising a chat drops the work bound to it' -Tag 'Unit' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $script:dataDir = Join-Path $TestDrive ('drop-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:dataDir | Out-Null
        $script:DeskPilot = New-TestAuthorityState -GroupAllowed -ProjectRemote -ProjectGroup
        $script:DeskPilot.Intercom = Initialize-DpIntercom -Directory $script:dataDir
        $script:DeskPilot.Intercom.TokenConfigured = $true
        $script:DeskPilot.Intercom.QueuedPrompt = 'build it'
        $script:DeskPilot.Intercom.QueuedChatId = $script:GroupChat
        $script:DeskPilot.Intercom.Download.stage = 'lookup'
        $script:DeskPilot.Intercom.Download.chatId = $script:GroupChat
        $script:responseStream = [System.IO.MemoryStream]::new()
        Mock Update-DpIntercomState { }
    }

    AfterEach {
        if ($script:DeskPilot.Intercom.Client) { $script:DeskPilot.Intercom.Client.Dispose() }
        $script:responseStream.Dispose()
        $script:DeskPilot = $null
    }

    It 'drops the attachment a de-authorised group was still sending' {
        Invoke-DpRouteHandler -Name 'putIntercom' -Stream $script:responseStream -Body ([pscustomobject]@{ allowGroupChat = $false })

        $script:DeskPilot.Intercom.QueuedPrompt | Should -BeNullOrEmpty
        $script:DeskPilot.Intercom.Download.stage | Should -Be ''
    }

    It 'drops work bound to the old chat when the operator relinks their phone' {
        $script:DeskPilot.Intercom.QueuedChatId = $script:OwnChat
        $script:DeskPilot.Intercom.Download.chatId = $script:OwnChat

        Invoke-DpRouteHandler -Name 'putIntercom' -Stream $script:responseStream -Body ([pscustomobject]@{ chatId = '222' })

        $script:DeskPilot.Intercom.QueuedPrompt | Should -BeNullOrEmpty
        $script:DeskPilot.Intercom.QueuedChatId | Should -BeNullOrEmpty
        $script:DeskPilot.Intercom.Download.stage | Should -Be ''
    }

    It 'leaves work alone when a different group is removed' {
        $script:DeskPilot.Settings.intercom.groupChatIds = @($script:GroupChat, '-1005550001')
        $body = [pscustomobject]@{ groupChatIds = @($script:GroupChat) }

        Invoke-DpRouteHandler -Name 'putIntercom' -Stream $script:responseStream -Body $body

        $script:DeskPilot.Intercom.QueuedPrompt | Should -Be 'build it'
        $script:DeskPilot.Intercom.Download.stage | Should -Be 'lookup'
    }
}

Describe 'FIND-006 - a failed getMe is recorded like every other Intercom error' -Tag 'Unit' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $script:dataDir = Join-Path $TestDrive ('id-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:dataDir | Out-Null
        $settings = Get-DpDefaultSettings
        $settings.intercom.enabled = $true
        $settings.intercom.chatId = '111'
        $script:DeskPilot = @{
            Settings      = $settings
            Conversations = @{}
            TurnRunning   = $false
            DataDir       = $script:dataDir
            Intercom      = Initialize-DpIntercom -Directory $script:dataDir
        }
        $script:DeskPilot.Intercom.TokenConfigured = $true
        $script:DeskPilot.Intercom.Token = '123456789:AAHqWeRtYuIoPaSdFgHjKlZxCvBnM12'
        $script:DeskPilot.Intercom.Running = $true
        $script:DeskPilot.Intercom.Priming = $false
        # Nothing may reach the network: an in-flight poll that never completes.
        Mock Invoke-DpTelegramRequest {
            ([System.Threading.Tasks.TaskCompletionSource[System.Net.Http.HttpResponseMessage]]::new()).Task
        }
    }

    AfterEach {
        if ($script:DeskPilot.Intercom.Client) { $script:DeskPilot.Intercom.Client.Dispose() }
        $script:DeskPilot = $null
    }

    It 'logs the refusal instead of swallowing it' {
        $body = '{"ok":false,"description":"Unauthorized"}'
        $failed = [System.Net.Http.HttpResponseMessage]::new(401)
        $failed.Content = [System.Net.Http.StringContent]::new($body, [System.Text.Encoding]::UTF8, 'application/json')
        $script:DeskPilot.Intercom.IdentityTask = [System.Threading.Tasks.Task]::FromResult($failed)

        Update-DpIntercomState

        @($script:DeskPilot.Intercom.Log | Where-Object { $_.kind -eq 'identity-error' }).Count | Should -Be 1
        $script:DeskPilot.Intercom.BotUsername | Should -BeNullOrEmpty
    }

    It 'records nothing and keeps the name when the lookup succeeds' {
        $body = '{"ok":true,"result":{"username":"Janis1bot"}}'
        $ok = [System.Net.Http.HttpResponseMessage]::new(200)
        $ok.Content = [System.Net.Http.StringContent]::new($body, [System.Text.Encoding]::UTF8, 'application/json')
        $script:DeskPilot.Intercom.IdentityTask = [System.Threading.Tasks.Task]::FromResult($ok)

        Update-DpIntercomState

        @($script:DeskPilot.Intercom.Log | Where-Object { $_.kind -eq 'identity-error' }).Count | Should -Be 0
        $script:DeskPilot.Intercom.BotUsername | Should -Be 'Janis1bot'
    }
}

Describe 'FIND-015 - a failed getMe names what it costs and is asked again' -Tag 'Unit' {
    BeforeAll {
        function New-TestIdentityTask {
            [CmdletBinding()]
            param(
                [int]$Status = 200,
                [string]$Body = '{"ok":true,"result":{"username":"Janis1bot"}}'
            )
            $response = [System.Net.Http.HttpResponseMessage]::new($Status)
            $response.Content = [System.Net.Http.StringContent]::new($Body, [System.Text.Encoding]::UTF8, 'application/json')
            [System.Threading.Tasks.Task]::FromResult($response)
        }
        $script:Refused = '{"ok":false,"description":"Unauthorized"}'
    }

    BeforeEach {
        Set-StrictMode -Version Latest
        $script:dataDir = Join-Path $TestDrive ('retry-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:dataDir | Out-Null
        $settings = Get-DpDefaultSettings
        $settings.intercom.enabled = $true
        $settings.intercom.chatId = '111'
        $script:DeskPilot = @{
            Settings      = $settings
            Conversations = @{}
            TurnRunning   = $false
            DataDir       = $script:dataDir
            Intercom      = Initialize-DpIntercom -Directory $script:dataDir
        }
        $script:DeskPilot.Intercom.TokenConfigured = $true
        $script:DeskPilot.Intercom.Token = '123456789:AAHqWeRtYuIoPaSdFgHjKlZxCvBnM12'
        $script:DeskPilot.Intercom.Running = $true
        $script:DeskPilot.Intercom.Priming = $false
        # Nothing may reach the network: polls and sends never complete, and a
        # lookup answers with the bot's name.
        Mock Invoke-DpTelegramRequest {
            ([System.Threading.Tasks.TaskCompletionSource[System.Net.Http.HttpResponseMessage]]::new()).Task
        }
        Mock Invoke-DpTelegramRequest -ParameterFilter { $Operation -eq 'getMe' } { New-TestIdentityTask }
    }

    AfterEach {
        if ($script:DeskPilot.Intercom.Client) { $script:DeskPilot.Intercom.Client.Dispose() }
        $script:DeskPilot = $null
    }

    It 'says no group Message gets through while a mention is required' {
        $script:DeskPilot.Settings.intercom.allowGroupChat = $true
        $script:DeskPilot.Settings.intercom.groupChatIds = @('-1004455397827')
        $script:DeskPilot.Settings.intercom.requireGroupMention = $true
        $script:DeskPilot.Intercom.IdentityAttempts = 1
        $script:DeskPilot.Intercom.IdentityTask = New-TestIdentityTask -Status 401 -Body $script:Refused

        Update-DpIntercomState

        $entries = @($script:DeskPilot.Intercom.Log | Where-Object { $_.kind -eq 'identity-error' })
        $entries.Count | Should -Be 1
        $entries[0].detail | Should -Match 'ignore every group Message except a reply to my question'
        $entries[0].detail | Should -Not -Match 'stay in the prompt'
    }

    It 'names the mention it cannot strip when no mention is required' {
        $script:DeskPilot.Intercom.IdentityAttempts = 1
        $script:DeskPilot.Intercom.IdentityTask = New-TestIdentityTask -Status 401 -Body $script:Refused

        Update-DpIntercomState

        @($script:DeskPilot.Intercom.Log | Where-Object { $_.kind -eq 'identity-error' })[0].detail |
            Should -Match 'leading @mention will stay in the prompt'
    }

    It 'asks again once the delay has passed, and learns the name' {
        $script:DeskPilot.Intercom.IdentityAttempts = 1
        $script:DeskPilot.Intercom.IdentityTask = New-TestIdentityTask -Status 401 -Body $script:Refused

        Update-DpIntercomState
        Update-DpIntercomState

        Should -Invoke Invoke-DpTelegramRequest -ParameterFilter { $Operation -eq 'getMe' } -Times 0 -Exactly
        ([DateTime]$script:DeskPilot.Intercom.IdentityRetryUtc - [DateTime]::UtcNow).TotalSeconds | Should -BeGreaterThan 0
        @($script:DeskPilot.Intercom.Log | Where-Object { $_.kind -eq 'identity-error' })[0].detail |
            Should -Match 'ask again in 30 seconds'

        $script:DeskPilot.Intercom.IdentityRetryUtc = [DateTime]::UtcNow.AddSeconds(-1)
        Update-DpIntercomState

        Should -Invoke Invoke-DpTelegramRequest -ParameterFilter { $Operation -eq 'getMe' } -Times 1 -Exactly
        $script:DeskPilot.Intercom.BotUsername | Should -Be 'Janis1bot'
        $script:DeskPilot.Intercom.IdentityAttempts | Should -Be 2
        # The earlier error line is answered, so it does not read as still true.
        @($script:DeskPilot.Intercom.Log | Where-Object { $_.kind -eq 'identity' }).Count | Should -Be 1
    }

    It 'stops asking after the last attempt and says how to try again' {
        $script:DeskPilot.Intercom.IdentityAttempts = 5
        $script:DeskPilot.Intercom.IdentityTask = New-TestIdentityTask -Status 401 -Body $script:Refused

        Update-DpIntercomState
        Update-DpIntercomState

        Should -Invoke Invoke-DpTelegramRequest -ParameterFilter { $Operation -eq 'getMe' } -Times 0 -Exactly
        $script:DeskPilot.Intercom.IdentityRetryUtc | Should -BeNullOrEmpty
        @($script:DeskPilot.Intercom.Log | Where-Object { $_.kind -eq 'identity-error' })[0].detail |
            Should -Match 'Send a test message'
    }

    It 'asks once when Intercom is switched on, without logging a success' {
        $script:DeskPilot.Intercom.Running = $false

        Update-DpIntercomState

        Should -Invoke Invoke-DpTelegramRequest -ParameterFilter { $Operation -eq 'getMe' } -Times 1 -Exactly
        $script:DeskPilot.Intercom.BotUsername | Should -Be 'Janis1bot'
        @($script:DeskPilot.Intercom.Log | Where-Object { $_.kind -like 'identity*' }).Count | Should -Be 0
    }

    It 'forgets the name an old token established when a new token is stored' {
        $script:DeskPilot.Intercom.BotUsername = 'Oldbot'
        $script:DeskPilot.Intercom.IdentityAttempts = 5
        $script:DeskPilot.Intercom.IdentityRetryUtc = [DateTime]::UtcNow.AddMinutes(10)
        Mock Save-DpIntercomSecret { $true }
        Mock Update-DpIntercomState { }
        $stream = [System.IO.MemoryStream]::new()
        try {
            Invoke-DpRouteHandler -Name 'putIntercom' -Stream $stream -Body ([pscustomobject]@{ botToken = '987654321:AAHqWeRtYuIoPaSdFgHjKlZxCvBnM12' })
        }
        finally { $stream.Dispose() }

        $script:DeskPilot.Intercom.BotUsername | Should -Be ''
        $script:DeskPilot.Intercom.IdentityTask | Should -BeNullOrEmpty
        $script:DeskPilot.Intercom.IdentityAttempts | Should -Be 0
        $script:DeskPilot.Intercom.IdentityRetryUtc | Should -BeNullOrEmpty
    }
}

Describe 'FIND-007 - a chat id is bounded by int64, not by a digit count' -Tag 'Unit' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $script:settings = Get-DpDefaultSettings
    }

    It 'refuses a group id that overflows int64' {
        { Merge-DpSettings -Current $script:settings -Patch @{ intercom = @{ groupChatIds = '-99999999999999999999' } } } |
            Should -Throw -ExpectedMessage '*64-bit integer*'
    }

    It 'refuses an operator chat id that overflows int64, on the same rule' {
        { Merge-DpSettings -Current $script:settings -Patch @{ intercom = @{ chatId = '99999999999999999999' } } } |
            Should -Throw -ExpectedMessage '*64-bit integer*'
    }

    It 'still accepts the ids Telegram actually issues' {
        $patch = @{ intercom = @{ chatId = '123456789'; groupChatIds = '-1004455397827' } }

        $merged = Merge-DpSettings -Current $script:settings -Patch $patch

        $merged.intercom.chatId | Should -Be '123456789'
        @($merged.intercom.groupChatIds) | Should -Be @('-1004455397827')
    }

    It 'accepts an id at the int64 boundary' {
        $merged = Merge-DpSettings -Current $script:settings -Patch @{ intercom = @{ groupChatIds = '-9223372036854775807' } }

        @($merged.intercom.groupChatIds) | Should -Be @('-9223372036854775807')
    }
}

Describe 'FIND-016 - group chatter not addressed to Intercom cannot flood the audit log' -Tag 'Unit' {
    BeforeAll {
        $script:SecondGroup = '-1005550001111'

        # The real intake chain: a raw Telegram update through the parser, then
        # the command executor that writes the audit log.
        function Receive-TestGroupMessage {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory)][string]$ChatId,
                [Parameter(Mandatory)][string]$Text,
                [object[]]$Entities = @()
            )

            $script:nextUpdateId++
            $update = @{
                update_id = $script:nextUpdateId
                message   = @{
                    message_id = $script:nextUpdateId
                    chat       = @{ id = $ChatId; type = 'supergroup' }
                    from       = @{ first_name = 'Mo'; username = 'mo' }
                    text       = $Text
                    entities   = @($Entities)
                }
            }
            $command = ConvertFrom-DpIntercomUpdate -Update $update @script:intakeParams
            $null = Invoke-DpIntercomCommand -Command $command
            $command
        }
    }

    BeforeEach {
        Set-StrictMode -Version Latest
        $script:DeskPilot = New-TestAuthorityState -GroupAllowed -ProjectRemote -ProjectGroup
        $script:DeskPilot.Settings.intercom.groupChatIds = @($script:GroupChat, $script:SecondGroup)
        $script:DeskPilot.Settings.intercom.requireGroupMention = $true
        $script:intakeParams = @{
            AllowedChatId       = $script:OwnChat
            AllowedGroupChatId  = @($script:GroupChat, $script:SecondGroup)
            BotUsername         = 'Janis1bot'
            RequireGroupMention = $true
        }
        $script:nextUpdateId = 100
    }

    AfterEach { $script:DeskPilot = $null }

    It 'keeps the rejection and the error a busy group would have evicted' {
        $rejected = New-TestCommand -Kind 'rejected' -ChatId '-1009999999999' -FromName 'Nobody'
        $rejected.reason = "Message from chat '-1009999999999' is not allow-listed."
        Invoke-DpIntercomCommand -Command $rejected
        Add-DpIntercomLog -Direction 'out' -Kind 'error' -Detail 'Telegram refused the message.' -Accepted $false

        1..250 | ForEach-Object { $null = Receive-TestGroupMessage -ChatId $script:GroupChat -Text "chatter $_" }

        $log = @($script:DeskPilot.Intercom.Log)
        @($log | Where-Object { $_.kind -eq 'rejected' }).Count | Should -Be 1
        @($log | Where-Object { $_.kind -eq 'error' }).Count | Should -Be 1
        $folded = @($log | Where-Object { $_.kind -eq 'unaddressed' })
        $folded.Count | Should -Be 1
        $folded[0]['messageCount'] | Should -Be 250
        $folded[0].chatId | Should -Be $script:GroupChat
        $script:DeskPilot.Intercom.Counters.received | Should -Be 251
    }

    It 'keeps the folded line newest and remembers when the chatter began' {
        $first = Receive-TestGroupMessage -ChatId $script:GroupChat -Text 'first chatter'
        $since = @($script:DeskPilot.Intercom.Log)[-1].sinceUtc
        $mentioned = Receive-TestGroupMessage -ChatId $script:GroupChat -Text '@Janis1bot ship it' `
            -Entities @(@{ type = 'mention'; offset = 0; length = 10 })
        $null = Receive-TestGroupMessage -ChatId $script:GroupChat -Text 'more chatter'

        $first.unaddressed | Should -BeTrue
        $mentioned.kind | Should -Be 'prompt'
        $log = @($script:DeskPilot.Intercom.Log)
        @($log | Where-Object { $_.kind -eq 'prompt' }).Count | Should -Be 1
        $log[-1].kind | Should -Be 'unaddressed'
        $log[-1]['messageCount'] | Should -Be 2
        $log[-1].sinceUtc | Should -Be $since
        $log[-1].utc | Should -Not -BeNullOrEmpty
        $log[-1].detail | Should -Be 'Group Message did not mention this Intercom.'
        $log[-1].accepted | Should -BeFalse
        # The line stands for several senders, so it names none of them.
        $log[-1].from | Should -Be ''
    }

    It 'folds each group into its own line' {
        $null = Receive-TestGroupMessage -ChatId $script:GroupChat -Text 'chatter'
        $null = Receive-TestGroupMessage -ChatId $script:SecondGroup -Text 'other chatter'
        $null = Receive-TestGroupMessage -ChatId $script:GroupChat -Text 'chatter again'

        $folded = @(@($script:DeskPilot.Intercom.Log) | Where-Object { $_.kind -eq 'unaddressed' })
        $folded.Count | Should -Be 2
        @($folded | Where-Object { $_.chatId -eq $script:GroupChat })[0]['messageCount'] | Should -Be 2
        @($folded | Where-Object { $_.chatId -eq $script:SecondGroup })[0]['messageCount'] | Should -Be 1
    }

    It 'folds a command meant for another bot into the same line' {
        $null = Receive-TestGroupMessage -ChatId $script:GroupChat -Text 'chatter'
        $command = Receive-TestGroupMessage -ChatId $script:GroupChat -Text '@Janis1bot /status@Otherbot' `
            -Entities @(@{ type = 'mention'; offset = 0; length = 10 })

        $command.reason | Should -Be 'Group command addresses a different Telegram username.'
        $folded = @(@($script:DeskPilot.Intercom.Log) | Where-Object { $_.kind -eq 'unaddressed' })
        $folded.Count | Should -Be 1
        $folded[0]['messageCount'] | Should -Be 2
        $folded[0].detail | Should -Be 'Group command addresses a different Telegram username.'
    }

    It 'still records every other ignored Message on its own line' {
        $ignored = New-TestCommand -Kind 'ignore' -ChatId $script:OwnChat
        $ignored.reason = 'Message carried no text.'

        Invoke-DpIntercomCommand -Command $ignored
        Invoke-DpIntercomCommand -Command $ignored

        @(@($script:DeskPilot.Intercom.Log) | Where-Object { $_.kind -eq 'ignored' }).Count | Should -Be 2
        @(@($script:DeskPilot.Intercom.Log) | Where-Object { $_.kind -eq 'unaddressed' }).Count | Should -Be 0
    }
}
