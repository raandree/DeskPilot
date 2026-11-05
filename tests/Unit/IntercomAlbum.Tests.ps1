#requires -Version 7.0

# Several files sent together from Telegram - an album - reach the bot as one
# Message per file, sharing a media_group_id, with the caption on just one of
# them. Intercom used to fetch the first file and refuse the rest with "One file
# at a time", so the caption was lost whenever it rode on a later file.
#
# These tests drive the real pump (Update-DpIntercomState) with Telegram mocked
# at its two network boundaries, so dispatch, the download state machine and the
# queued prompt are exercised together.

BeforeAll {
    # The module runs under Set-StrictMode -Version Latest (source/Prefix.ps1),
    # where reading a missing hashtable key is a terminating error rather than
    # $null.
    Set-StrictMode -Version Latest
    $privateRoot = Join-Path $PSScriptRoot '..' '..' 'source' 'Private'
    Get-ChildItem -Path $privateRoot -Filter '*.ps1' | ForEach-Object { . $_.FullName }

    $script:OwnChat = '111'
    $script:GroupChat = '-1004455397827'

    function New-TestFileMessage {
        [CmdletBinding()]
        [OutputType([hashtable])]
        [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'A test helper that builds an in-memory Telegram Message; it changes nothing.')]
        param(
            [Parameter(Mandatory)]
            [string]$FileId,

            [string]$FileName = '',

            [string]$Album = '',

            [string]$Caption = '',

            [object[]]$CaptionEntities = @(),

            [string]$ChatId = '111',

            [switch]$Photo
        )

        $script:nextMessageId++
        $message = @{
            message_id = $script:nextMessageId
            chat       = @{ id = $ChatId; type = $(if ($ChatId.StartsWith('-')) { 'supergroup' } else { 'private' }) }
            from       = @{ first_name = 'Sam' }
        }
        if ($Photo) {
            $message.photo = @(
                @{ file_id = "$FileId-small"; file_size = 100 }
                @{ file_id = $FileId; file_size = 2048 }
            )
        }
        else {
            $message.document = @{ file_id = $FileId; file_name = $FileName; mime_type = 'application/pdf'; file_size = 2048 }
        }
        if ($Album) { $message.media_group_id = $Album }
        if ($Caption) {
            $message.caption = $Caption
            $message.caption_entities = $CaptionEntities
        }
        $message
    }

    function Set-TestPoll {
        # Hands the pump one completed getUpdates carrying these Messages.
        [CmdletBinding()]
        [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'A test helper that queues an in-memory poll result; it changes nothing outside the test.')]
        param(
            [Parameter(Mandatory)]
            [object[]]$Message
        )

        $updates = foreach ($item in $Message) {
            $script:nextUpdateId++
            @{ update_id = $script:nextUpdateId; message = $item }
        }
        $body = @{ ok = $true; result = @($updates) } | ConvertTo-Json -Depth 8
        $httpResponse = [System.Net.Http.HttpResponseMessage]::new(200)
        $httpResponse.Content = [System.Net.Http.StringContent]::new($body, [System.Text.Encoding]::UTF8, 'application/json')
        $script:DeskPilot.Intercom.PollTask = [System.Threading.Tasks.Task]::FromResult($httpResponse)
    }

    function Invoke-TestPump {
        # Every Telegram call completes at once here, so a fixed number of ticks
        # is enough to fetch every file; each tick is cheap.
        [CmdletBinding()]
        param(
            [int]$Tick = 100
        )

        for ($index = 0; $index -lt $Tick; $index++) { Update-DpIntercomState }
    }

    function Complete-TestAlbumWait {
        # The prompt for an album is queued only once no file of it has arrived
        # for a moment. Backdate that moment, as the stall tests backdate theirs.
        [CmdletBinding()]
        [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'A test helper that moves an in-memory clock; it changes nothing outside the test.')]
        param()

        $script:DeskPilot.Intercom.Download.lastItemUtc = [DateTime]::UtcNow.AddMinutes(-1)
    }

    function Get-TestSavedPath {
        [CmdletBinding()]
        [OutputType([string])]
        param(
            [Parameter(Mandatory)]
            [string]$Name
        )

        [System.IO.Path]::GetFullPath((Join-Path $script:workspace $Name))
    }
}

Describe 'Intercom fetches every file sent together' -Tag 'Unit' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $script:dataDir = Join-Path $TestDrive ('album-' + [guid]::NewGuid().ToString('N'))
        $script:workspace = Join-Path $script:dataDir 'project'
        New-Item -ItemType Directory -Path $script:workspace -Force | Out-Null

        $settings = Get-DpDefaultSettings
        $settings.workspaceFolder = $script:workspace
        $settings.intercom.enabled = $true
        $settings.intercom.chatId = $script:OwnChat
        $settings.projects = @(@{ id = 'p1'; name = 'Lab'; path = $script:workspace; intercom = $true; intercomGroup = $true })
        $settings.selectedProjectId = 'p1'

        $script:DeskPilot = @{
            Settings      = $settings
            Conversations = @{}
            TurnRunning   = $false
            DataDir       = $script:dataDir
            Attachments   = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            Intercom      = Initialize-DpIntercom -Directory $script:dataDir
        }
        $script:DeskPilot.Intercom.TokenConfigured = $true
        $script:DeskPilot.Intercom.Token = '123456789:AAHqWeRtYuIoPaSdFgHjKlZxCvBnM12'
        $script:DeskPilot.Intercom.Running = $true
        $script:DeskPilot.Intercom.Priming = $false
        $script:DeskPilot.Intercom.BotUsername = 'Janis1bot'
        $script:DeskPilot.Intercom.LastHeartbeatUtc = [DateTime]::UtcNow

        $script:nextUpdateId = 100
        $script:nextMessageId = 500
        $script:failFileId = @()
        $script:getFileCalls = [System.Collections.Generic.List[string]]::new()
        $script:sent = [System.Collections.Generic.List[hashtable]]::new()

        # getFile answers at once; every poll and send stays in flight, so
        # nothing reaches the network.
        Mock Invoke-DpTelegramRequest {
            if ($Operation -ne 'getFile') {
                return ([System.Threading.Tasks.TaskCompletionSource[System.Net.Http.HttpResponseMessage]]::new()).Task
            }
            $fileId = [string]$Payload.file_id
            $script:getFileCalls.Add($fileId)
            $envelope = if ($script:failFileId -contains $fileId) {
                @{ ok = $false; description = 'Bad Request: file is temporarily unavailable' }
            }
            else {
                @{ ok = $true; result = @{ file_id = $fileId; file_path = "documents/$fileId.bin" } }
            }
            $httpResponse = [System.Net.Http.HttpResponseMessage]::new(200)
            $httpResponse.Content = [System.Net.Http.StringContent]::new(($envelope | ConvertTo-Json -Depth 4), [System.Text.Encoding]::UTF8, 'application/json')
            [System.Threading.Tasks.Task]::FromResult($httpResponse)
        }
        Mock Invoke-DpTelegramFileRequest {
            $httpResponse = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::OK)
            $httpResponse.Content = [System.Net.Http.ByteArrayContent]::new([System.Text.Encoding]::UTF8.GetBytes("content of $FilePath"))
            [System.Threading.Tasks.Task]::FromResult($httpResponse)
        }
        Mock Send-DpIntercomMessage {
            $script:sent.Add(@{
                    title  = $Title
                    lines  = @($Line)
                    kind   = $Kind
                    chatId = [string](Get-DpPropertyValue -InputObject $script:DeskPilot.Intercom -Name @('ReplyChatId') -Default '')
                })
            $true
        }
    }

    AfterEach {
        if ($script:DeskPilot.Intercom.Client) { $script:DeskPilot.Intercom.Client.Dispose() }
        $script:DeskPilot = $null
    }

    It 'runs the caption of a six-file album once, with all six files' {
        # The reported case: six PDFs sent together from Telegram Desktop, with
        # the caption riding on the last of them.
        $names = 0..5 | ForEach-Object { "Lab 0$_ - DevOps Fundamentals.pdf" }
        $messages = for ($index = 0; $index -lt 6; $index++) {
            $caption = if ($index -eq 5) { 'here are 6 files, store them' } else { '' }
            New-TestFileMessage -FileId "doc$index" -FileName $names[$index] -Album 'album-1' -Caption $caption
        }
        Set-TestPoll -Message $messages

        Invoke-TestPump
        Complete-TestAlbumWait
        Invoke-TestPump -Tick 1

        $prompt = [string]$script:DeskPilot.Intercom.QueuedPrompt
        $prompt | Should -Match '^here are 6 files, store them'
        foreach ($name in $names) {
            $saved = Get-TestSavedPath -Name $name
            Test-Path -LiteralPath $saved | Should -BeTrue
            $prompt | Should -Match ([regex]::Escape("[Attached file: $saved]"))
        }
        $script:DeskPilot.Intercom.QueuedChatId | Should -Be $script:OwnChat
        @($script:sent | Where-Object { $_.title -like 'One file at a time*' }).Count | Should -Be 0
        @($script:sent | Where-Object { $_.title -eq 'Got 6 files. Working on them.' }).Count | Should -Be 1
    }

    It 'waits for the rest of an album that arrives in a later poll' {
        Set-TestPoll -Message @(New-TestFileMessage -FileId 'doc0' -FileName 'first.pdf' -Album 'album-2' -Caption 'compare these')
        Invoke-TestPump

        # The first file has landed, but its album has not gone quiet yet.
        Test-Path -LiteralPath (Get-TestSavedPath -Name 'first.pdf') | Should -BeTrue
        $script:DeskPilot.Intercom.QueuedPrompt | Should -BeNullOrEmpty

        Set-TestPoll -Message @(New-TestFileMessage -FileId 'doc1' -FileName 'second.pdf' -Album 'album-2')
        Invoke-TestPump
        Complete-TestAlbumWait
        Invoke-TestPump -Tick 1

        $prompt = [string]$script:DeskPilot.Intercom.QueuedPrompt
        $prompt | Should -Match '^compare these'
        $prompt | Should -Match ([regex]::Escape((Get-TestSavedPath -Name 'first.pdf')))
        $prompt | Should -Match ([regex]::Escape((Get-TestSavedPath -Name 'second.pdf')))
    }

    It 'still runs a single file as soon as it lands' {
        # Characterisation: a file outside an album keeps today's behaviour.
        Set-TestPoll -Message @(New-TestFileMessage -FileId 'doc0' -FileName 'notes.pdf')

        Invoke-TestPump

        $saved = Get-TestSavedPath -Name 'notes.pdf'
        $script:DeskPilot.Intercom.QueuedPrompt | Should -Be "Have a look at this file and tell me what it is.`n`n[Attached file: $saved]"
        @($script:sent | Where-Object { $_.title -eq 'Got the file. Working on it.' }).Count | Should -Be 1
    }

    It 'hands every photo of an album to the Vision input' {
        $messages = @(
            New-TestFileMessage -FileId 'pic0' -Album 'album-3' -Photo -Caption 'what differs?'
            New-TestFileMessage -FileId 'pic1' -Album 'album-3' -Photo
            New-TestFileMessage -FileId 'pic2' -Album 'album-3' -Photo
        )
        Set-TestPoll -Message $messages

        Invoke-TestPump
        Complete-TestAlbumWait
        Invoke-TestPump -Tick 1

        $images = @($script:DeskPilot.Intercom.QueuedImage)
        $images.Count | Should -Be 3
        foreach ($image in $images) {
            Test-Path -LiteralPath $image | Should -BeTrue
            [string]$script:DeskPilot.Intercom.QueuedPrompt | Should -Match ([regex]::Escape("[Attached file: $image]"))
        }
    }

    It 'runs with the files that landed and names the one that did not' {
        $script:failFileId = @('doc1')
        $messages = @(
            New-TestFileMessage -FileId 'doc0' -FileName 'a.pdf' -Album 'album-4' -Caption 'summarise these'
            New-TestFileMessage -FileId 'doc1' -FileName 'b.pdf' -Album 'album-4'
            New-TestFileMessage -FileId 'doc2' -FileName 'c.pdf' -Album 'album-4'
        )
        Set-TestPoll -Message $messages

        Invoke-TestPump
        Complete-TestAlbumWait
        Invoke-TestPump -Tick 1

        $prompt = [string]$script:DeskPilot.Intercom.QueuedPrompt
        $prompt | Should -Match ([regex]::Escape((Get-TestSavedPath -Name 'a.pdf')))
        $prompt | Should -Match ([regex]::Escape((Get-TestSavedPath -Name 'c.pdf')))
        $prompt | Should -Not -Match 'b\.pdf'
        $report = @($script:sent | Where-Object { $_.title -eq 'Got 2 of 3 files. Working on them.' })
        $report.Count | Should -Be 1
        ($report[0].lines -join "`n") | Should -Match 'b\.pdf'
    }

    It 'leaves an instruction that is already queued alone' {
        $script:DeskPilot.Intercom.QueuedPrompt = 'finish the report'
        $script:DeskPilot.Intercom.QueuedChatId = $script:OwnChat
        Set-TestPoll -Message @(New-TestFileMessage -FileId 'doc0' -FileName 'late.pdf')

        Invoke-TestPump

        $script:DeskPilot.Intercom.QueuedPrompt | Should -Be 'finish the report'
        Test-Path -LiteralPath (Get-TestSavedPath -Name 'late.pdf') | Should -BeTrue
        $notice = @($script:sent | Where-Object { $_.title -eq 'One instruction is already queued.' })
        $notice.Count | Should -Be 1
        ($notice[0].lines -join "`n") | Should -Match 'late\.pdf'
    }

    It 'takes at most 20 files at a time and says how many it left' {
        # Telegram splits more than ten files into several albums.
        $messages = for ($index = 0; $index -lt 21; $index++) {
            New-TestFileMessage -FileId "doc$index" -FileName "file$index.pdf" -Album "album-$([int][Math]::Floor($index / 10))"
        }
        Set-TestPoll -Message $messages

        Invoke-TestPump
        Complete-TestAlbumWait
        Invoke-TestPump -Tick 1

        $script:getFileCalls.Count | Should -Be 20
        ([regex]::Matches([string]$script:DeskPilot.Intercom.QueuedPrompt, '\[Attached file: ')).Count | Should -Be 20
        $report = @($script:sent | Where-Object { $_.title -eq 'Got 20 files. Working on them.' })
        $report.Count | Should -Be 1
        ($report[0].lines -join "`n") | Should -Match '1 more file was not taken'
    }

    It 'asks a second chat to wait, once, without disturbing the batch' {
        $script:DeskPilot.Settings.intercom.allowGroupChat = $true
        $script:DeskPilot.Settings.intercom.groupChatIds = @($script:GroupChat)
        $script:DeskPilot.Settings.intercom.requireGroupMention = $false
        $messages = @(
            New-TestFileMessage -FileId 'doc0' -FileName 'mine-1.pdf' -Album 'album-5'
            New-TestFileMessage -FileId 'doc1' -FileName 'theirs-1.pdf' -ChatId $script:GroupChat
            New-TestFileMessage -FileId 'doc2' -FileName 'mine-2.pdf' -Album 'album-5'
            New-TestFileMessage -FileId 'doc3' -FileName 'theirs-2.pdf' -ChatId $script:GroupChat
        )
        Set-TestPoll -Message $messages

        Invoke-TestPump
        Complete-TestAlbumWait
        Invoke-TestPump -Tick 1

        $prompt = [string]$script:DeskPilot.Intercom.QueuedPrompt
        $prompt | Should -Match 'mine-1\.pdf'
        $prompt | Should -Match 'mine-2\.pdf'
        $prompt | Should -Not -Match 'theirs'
        $script:DeskPilot.Intercom.QueuedChatId | Should -Be $script:OwnChat
        $waits = @($script:sent | Where-Object { $_.chatId -eq $script:GroupChat })
        $waits.Count | Should -Be 1
        $waits[0].title | Should -Be 'One set of files at a time, please.'
    }

    It 'drops what it was fetching, and the images queued with it, when Intercom is switched off' {
        # Running work sent an hour ago, the moment Intercom comes back on, is
        # exactly the surprise the startup backlog is discarded to avoid.
        Set-TestPoll -Message @(
            New-TestFileMessage -FileId 'doc0' -FileName 'a.pdf' -Album 'album-10' -Caption 'store these'
            New-TestFileMessage -FileId 'doc1' -FileName 'b.pdf' -Album 'album-10'
        )
        Invoke-TestPump -Tick 2
        $script:DeskPilot.Intercom.QueuedPrompt = 'compare these'
        $script:DeskPilot.Intercom.QueuedImage = @('C:\shots\old.png')

        $script:DeskPilot.Settings.intercom.enabled = $false
        Invoke-TestPump -Tick 1
        $script:DeskPilot.Settings.intercom.enabled = $true
        Invoke-TestPump
        Complete-TestAlbumWait
        Invoke-TestPump -Tick 1

        $script:DeskPilot.Intercom.QueuedPrompt | Should -BeNullOrEmpty
        $script:DeskPilot.Intercom.QueuedImage | Should -BeNullOrEmpty
        Test-Path -LiteralPath (Get-TestSavedPath -Name 'b.pdf') | Should -BeFalse
    }

    Context 'in a group that must mention Intercom' {
        BeforeEach {
            $script:DeskPilot.Settings.intercom.allowGroupChat = $true
            $script:DeskPilot.Settings.intercom.groupChatIds = @($script:GroupChat)
            $script:DeskPilot.Settings.intercom.requireGroupMention = $true
            $script:mention = @(@{ type = 'mention'; offset = 0; length = 10 })
        }

        It 'fetches every file when the caption on the last file mentions Intercom' {
            $messages = @(
                New-TestFileMessage -FileId 'doc0' -FileName 'a.pdf' -Album 'album-6' -ChatId $script:GroupChat
                New-TestFileMessage -FileId 'doc1' -FileName 'b.pdf' -Album 'album-6' -ChatId $script:GroupChat
                New-TestFileMessage -FileId 'doc2' -FileName 'c.pdf' -Album 'album-6' -ChatId $script:GroupChat -Caption '@Janis1bot store these' -CaptionEntities $script:mention
            )
            Set-TestPoll -Message $messages

            Invoke-TestPump
            Complete-TestAlbumWait
            Invoke-TestPump -Tick 1

            $prompt = [string]$script:DeskPilot.Intercom.QueuedPrompt
            $prompt | Should -Match '^store these'
            foreach ($name in 'a.pdf', 'b.pdf', 'c.pdf') {
                $prompt | Should -Match ([regex]::Escape((Get-TestSavedPath -Name $name)))
            }
            $script:DeskPilot.Intercom.QueuedChatId | Should -Be $script:GroupChat
        }

        It 'fetches the rest of a photo album whose first photo mentions Intercom' {
            $messages = @(
                New-TestFileMessage -FileId 'pic0' -Album 'album-7' -Photo -ChatId $script:GroupChat -Caption '@Janis1bot what differs?' -CaptionEntities $script:mention
                New-TestFileMessage -FileId 'pic1' -Album 'album-7' -Photo -ChatId $script:GroupChat
            )
            Set-TestPoll -Message $messages

            Invoke-TestPump
            Complete-TestAlbumWait
            Invoke-TestPump -Tick 1

            @($script:DeskPilot.Intercom.QueuedImage).Count | Should -Be 2
            [string]$script:DeskPilot.Intercom.QueuedPrompt | Should -Match '^what differs\?'
        }

        It 'fetches nothing from an album that never mentions Intercom, and forgets it' {
            $messages = @(
                New-TestFileMessage -FileId 'doc0' -FileName 'a.pdf' -Album 'album-8' -ChatId $script:GroupChat
                New-TestFileMessage -FileId 'doc1' -FileName 'b.pdf' -Album 'album-8' -ChatId $script:GroupChat -Caption 'holiday pictures'
            )
            Set-TestPoll -Message $messages

            Invoke-TestPump
            Complete-TestAlbumWait
            Invoke-TestPump -Tick 1

            $script:getFileCalls.Count | Should -Be 0
            $script:sent.Count | Should -Be 0
            $script:DeskPilot.Intercom.QueuedPrompt | Should -BeNullOrEmpty

            foreach ($held in @($script:DeskPilot.Intercom.Download['held'])) { $held.receivedUtc = [DateTime]::UtcNow.AddMinutes(-5) }
            Invoke-TestPump -Tick 1

            @($script:DeskPilot.Intercom.Download['held']).Count | Should -Be 0
        }
    }
}

Describe 'ConvertFrom-DpIntercomUpdate reads an album' -Tag 'Unit' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $script:nextMessageId = 500
    }

    It 'carries the album id of a file Message' {
        $update = @{ update_id = 1; message = (New-TestFileMessage -FileId 'doc0' -FileName 'a.pdf' -Album 'album-1') }

        $result = ConvertFrom-DpIntercomUpdate -Update $update -AllowedChatId $script:OwnChat

        $result.kind | Should -Be 'prompt'
        $result['mediaGroupId'] | Should -Be 'album-1'
    }

    It 'keeps the file, never the words, of an album Message that does not mention Intercom' {
        $update = @{ update_id = 1; message = (New-TestFileMessage -FileId 'doc0' -FileName 'a.pdf' -Album 'album-1' -ChatId $script:GroupChat -Caption 'private chatter') }

        $result = ConvertFrom-DpIntercomUpdate -Update $update -AllowedChatId $script:OwnChat -AllowedGroupChatId @($script:GroupChat) -BotUsername 'Janis1bot' -RequireGroupMention $true

        $result.kind | Should -Be 'ignore'
        $result.unaddressed | Should -BeTrue
        $result.text | Should -BeNullOrEmpty
        $result.preview | Should -BeNullOrEmpty
        $result.attachment.fileId | Should -Be 'doc0'
        $result['mediaGroupId'] | Should -Be 'album-1'
    }

    It 'keeps no file from an unaddressed group Message outside an album' {
        $update = @{ update_id = 1; message = (New-TestFileMessage -FileId 'doc0' -FileName 'a.pdf' -ChatId $script:GroupChat) }

        $result = ConvertFrom-DpIntercomUpdate -Update $update -AllowedChatId $script:OwnChat -AllowedGroupChatId @($script:GroupChat) -BotUsername 'Janis1bot' -RequireGroupMention $true

        $result.kind | Should -Be 'ignore'
        $result.attachment | Should -BeNullOrEmpty
    }

    It 'keeps no file from an album Message of a chat that is not allow-listed' {
        $update = @{ update_id = 1; message = (New-TestFileMessage -FileId 'doc0' -FileName 'a.pdf' -Album 'album-1' -ChatId '999') }

        $result = ConvertFrom-DpIntercomUpdate -Update $update -AllowedChatId $script:OwnChat

        $result.kind | Should -Be 'rejected'
        $result.attachment | Should -BeNullOrEmpty
        $result['mediaGroupId'] | Should -BeNullOrEmpty
    }
}

Describe 'A Turn started from the phone sees every image' -Tag 'Unit' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $script:dataDir = Join-Path $TestDrive ('turn-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:dataDir | Out-Null
        $settings = Get-DpDefaultSettings
        $settings.intercom.enabled = $true
        $settings.intercom.chatId = $script:OwnChat
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
        $script:DeskPilot.Intercom.BotUsername = 'Janis1bot'
        $script:DeskPilot.Intercom.LastHeartbeatUtc = [DateTime]::UtcNow
        Mock Invoke-DpTelegramRequest {
            ([System.Threading.Tasks.TaskCompletionSource[System.Net.Http.HttpResponseMessage]]::new()).Task
        }
    }

    AfterEach {
        if ($script:DeskPilot.Intercom.Client) { $script:DeskPilot.Intercom.Client.Dispose() }
        $script:DeskPilot = $null
    }

    It 'passes every queued image to the Turn' {
        $script:DeskPilot.Intercom.QueuedPrompt = 'compare these'
        $script:DeskPilot.Intercom.QueuedImage = @('C:\shots\a.png', 'C:\shots\b.png')
        Mock Invoke-DpIntercomTurn { $script:turnImages = @($Image) }

        Update-DpIntercomState -AllowTurn

        $script:turnImages | Should -Be @('C:\shots\a.png', 'C:\shots\b.png')
        $script:DeskPilot.Intercom.QueuedImage | Should -BeNullOrEmpty
    }

    It 'gives the Engine every image it was handed' {
        Mock Invoke-DpTurn { $script:engineImages = @($Image) }
        Mock Send-DpIntercomTurnResult { }
        Mock Send-DpIntercomMessage { $true }

        Invoke-DpIntercomTurn -Prompt 'compare these' -Image @('C:\shots\a.png', 'C:\shots\b.png')

        $script:engineImages | Should -Be @('C:\shots\a.png', 'C:\shots\b.png')
    }
}
