#requires -Version 7.0

BeforeAll {
    # The module runs under Set-StrictMode -Version Latest (source/Prefix.ps1),
    # where reading a missing hashtable key is a terminating error rather than
    # $null. Tests that run without it validate different semantics than
    # production.
    Set-StrictMode -Version Latest
    $privateRoot = Join-Path $PSScriptRoot '..' '..' 'source' 'Private'
    Get-ChildItem -Path $privateRoot -Filter '*.ps1' | ForEach-Object { . $_.FullName }

    function New-TestIntercomState {
        [CmdletBinding()]
        [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'A test helper that builds in-memory state; it changes nothing on disk.')]
        param([string]$AgentsRoot, [object[]]$Projects = @(), [string]$SelectedProjectId)

        $settings = Get-DpDefaultSettings
        $settings.intercom.chatId = '111'
        $settings.agentsRoot = $AgentsRoot
        $settings.projects = @($Projects)
        $settings.selectedProjectId = $SelectedProjectId
        $settings.workspaceFolder = $null
        if ($SelectedProjectId) {
            $settings.workspaceFolder = [string](@($Projects) | Where-Object { $_.id -eq $SelectedProjectId } | Select-Object -First 1 -ExpandProperty path)
        }

        @{
            Settings              = $settings
            Conversations         = @{}
            TurnRunning           = $false
            DataDir               = $null
            ConversationsRevision = 0
            Intercom              = @{
                ConversationId = $null
                ChatIndex      = @()
                AgentIndex     = @()
                ProjectIndex   = @()
                QueuedPrompt   = $null
                Outbound       = [System.Collections.Generic.Queue[hashtable]]::new()
                RateWindow     = [System.Collections.Generic.List[DateTime]]::new()
                Log            = [System.Collections.Generic.List[object]]::new()
                Counters       = @{ received = 0; accepted = 0; rejected = 0; sent = 0; dropped = 0; errors = 0 }
                Token          = ''
            }
        }
    }

    function Get-TestOutboundText {
        [CmdletBinding()]
        param()
        @($script:DeskPilot.Intercom.Outbound.ToArray() | ForEach-Object { $_.text }) -join "`n"
    }
}

Describe 'ConvertFrom-DpIntercomUpdate parses the navigation commands' -Tag 'Unit' {
    BeforeAll {
        function New-TestNavUpdate {
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
        $cases = @{
            '/agents'                    = 'agents'
            '/agent 2'                   = 'agent'
            '/agent none'                = 'agent'
            '/projects'                  = 'projects'
            '/project 2'                 = 'project'
            '/project new C:\Git\Notes'  = 'project'
        }
        foreach ($text in $cases.Keys) {
            (ConvertFrom-DpIntercomUpdate -Update (New-TestNavUpdate -Text $text) -AllowedChatId '111').kind |
                Should -Be $cases[$text] -Because "'$text' must parse as $($cases[$text])"
        }
    }

    It 'carries the argument through untouched' {
        (ConvertFrom-DpIntercomUpdate -Update (New-TestNavUpdate -Text '/project new C:\Git\My Notes') -AllowedChatId '111').text |
            Should -Be 'new C:\Git\My Notes'
        (ConvertFrom-DpIntercomUpdate -Update (New-TestNavUpdate -Text '/agent  3 ') -AllowedChatId '111').text | Should -Be '3'
    }

    It 'still rejects them from a chat that is not allow-listed' {
        $result = ConvertFrom-DpIntercomUpdate -Update (New-TestNavUpdate -Text '/project new C:\Git\Notes') -AllowedChatId '999'

        $result.kind | Should -Be 'rejected'
        $result.text | Should -BeNullOrEmpty
    }
}

Describe 'Intercom agent navigation' -Tag 'Unit' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $script:agentsRoot = Join-Path $TestDrive 'agents'
        New-Item -ItemType Directory -Path $script:agentsRoot -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:agentsRoot 'alpha.agent.md') -Value "---`nname: Alpha`n---`nBody"
        Set-Content -LiteralPath (Join-Path $script:agentsRoot 'zulu.agent.md') -Value 'No frontmatter here.'

        $script:DeskPilot = New-TestIntercomState -AgentsRoot $script:agentsRoot
        $script:DeskPilot.Settings.selectedAgent = 'zulu.agent.md'
    }

    AfterEach { $script:DeskPilot = $null }

    It 'numbers the agents and marks the selected one' {
        $agents = @(Get-DpIntercomAgentList)

        $agents.Count | Should -Be 2
        $agents[0].number | Should -Be 1
        $agents[0].name | Should -Be 'Alpha'
        # No frontmatter: the file stem is the display name.
        $agents[1].name | Should -Be 'zulu'
        @($agents | Where-Object { $_.current }).id | Should -Be 'zulu.agent.md'
    }

    It 'returns nothing when no agents folder is configured or present' {
        $script:DeskPilot.Settings.agentsRoot = Join-Path $TestDrive 'nowhere'

        @(Get-DpIntercomAgentList).Count | Should -Be 0
    }

    It 'sends the list and remembers what each number meant' {
        Invoke-DpIntercomCommand -Command @{ kind = 'agents'; text = ''; reason = '' }

        $script:DeskPilot.Intercom.AgentIndex | Should -Be @('alpha.agent.md', 'zulu.agent.md')
        Get-TestOutboundText | Should -Match '1\. Alpha'
        Get-TestOutboundText | Should -Match '2\. zulu\s+<- current'
    }

    It 'switches to the number the operator was shown' {
        Invoke-DpIntercomCommand -Command @{ kind = 'agents'; text = ''; reason = '' }
        Invoke-DpIntercomCommand -Command @{ kind = 'agent'; text = '1'; reason = '' }

        $script:DeskPilot.Settings.selectedAgent | Should -Be 'alpha.agent.md'
        Get-TestOutboundText | Should -Match 'Switched agent'
    }

    It 'clears the selection on /agent none' {
        Invoke-DpIntercomCommand -Command @{ kind = 'agent'; text = 'none'; reason = '' }

        $script:DeskPilot.Settings.selectedAgent | Should -BeNullOrEmpty
        Get-TestOutboundText | Should -Match 'Agent cleared'
    }

    It 'refuses a number that is not on the list' {
        Invoke-DpIntercomCommand -Command @{ kind = 'agent'; text = '99'; reason = '' }

        $script:DeskPilot.Settings.selectedAgent | Should -Be 'zulu.agent.md'
        Get-TestOutboundText | Should -Match 'no agent 99'
    }

    It 'refuses something that is not a number' {
        Invoke-DpIntercomCommand -Command @{ kind = 'agent'; text = 'the reviewer one'; reason = '' }

        $script:DeskPilot.Settings.selectedAgent | Should -Be 'zulu.agent.md'
        Get-TestOutboundText | Should -Match 'not a number'
    }

    It 'needs no opted-in Project, because selecting an agent runs nothing' {
        # No Project is selected at all here, which refuses every command that works.
        Invoke-DpIntercomCommand -Command @{ kind = 'agent'; text = '1'; reason = '' }

        $script:DeskPilot.Settings.selectedAgent | Should -Be 'alpha.agent.md'
    }

    It 'says so when there is no agent to pick' {
        Remove-Item -LiteralPath (Join-Path $script:agentsRoot 'alpha.agent.md')
        Remove-Item -LiteralPath (Join-Path $script:agentsRoot 'zulu.agent.md')

        Invoke-DpIntercomCommand -Command @{ kind = 'agents'; text = ''; reason = '' }

        Get-TestOutboundText | Should -Match 'no agents to pick from'
    }

    It 'switches on a tapped agent button' {
        Invoke-DpIntercomCommand -Command @{ kind = 'agents'; text = ''; reason = '' }

        Invoke-DpIntercomCallback -Command @{ kind = 'callback'; callbackId = 'cb1'; text = 'g|1' }

        $script:DeskPilot.Settings.selectedAgent | Should -Be 'alpha.agent.md'
    }

    It 'refuses a button from a listing that has moved on' {
        # Telegram leaves old buttons on screen forever, and an agent button
        # carries a number rather than an id, so an index nothing backs any more
        # must refuse rather than land on whatever now sits at that position.
        Invoke-DpIntercomCallback -Command @{ kind = 'callback'; callbackId = 'cb1'; text = 'g|1' }

        $script:DeskPilot.Settings.selectedAgent | Should -Be 'zulu.agent.md'
        Get-TestOutboundText | Should -Match 'moved on'
    }
}

Describe 'Intercom project navigation' -Tag 'Unit' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $script:projectRoot = Join-Path $TestDrive 'work'
        New-Item -ItemType Directory -Path (Join-Path $script:projectRoot 'lab') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:projectRoot 'notes') -Force | Out-Null

        $projects = @(
            @{ id = 'p1'; name = 'Lab'; path = (Join-Path $script:projectRoot 'lab'); intercom = $true }
            @{ id = 'p2'; name = 'Notes'; path = (Join-Path $script:projectRoot 'notes'); intercom = $false }
        )
        $script:DeskPilot = New-TestIntercomState -Projects $projects -SelectedProjectId 'p1'
    }

    AfterEach { $script:DeskPilot = $null }

    It 'numbers the projects, marks the open one and reports the remote flag' {
        $projects = @(Get-DpIntercomProjectList)

        $projects.Count | Should -Be 2
        @($projects | Where-Object { $_.current }).id | Should -Be 'p1'
        @($projects | Where-Object { $_.remote }).id | Should -Be 'p1'
    }

    It 'sends the list and remembers what each number meant' {
        Invoke-DpIntercomCommand -Command @{ kind = 'projects'; text = ''; reason = '' }

        $script:DeskPilot.Intercom.ProjectIndex | Should -Be @('p1', 'p2')
        Get-TestOutboundText | Should -Match '1\. Lab\s+<- current'
        # The fact that decides whether the next instruction runs at all is on the
        # line, not left to be discovered through a refusal.
        Get-TestOutboundText | Should -Match '2\. Notes\s+\(remote control off\)'
    }

    It 'switches to the number the operator was shown and derives the workspace folder' {
        Invoke-DpIntercomCommand -Command @{ kind = 'projects'; text = ''; reason = '' }
        Invoke-DpIntercomCommand -Command @{ kind = 'project'; text = '2'; reason = '' }

        $script:DeskPilot.Settings.selectedProjectId | Should -Be 'p2'
        $script:DeskPilot.Settings.workspaceFolder | Should -Be (Join-Path $script:projectRoot 'notes')
    }

    It 'states that the project it switched to cannot be worked in from the phone' {
        Invoke-DpIntercomCommand -Command @{ kind = 'project'; text = '2'; reason = '' }

        Get-TestOutboundText | Should -Match 'Remote control is off for this project'
    }

    It 'refuses a number that is not on the list' {
        Invoke-DpIntercomCommand -Command @{ kind = 'project'; text = '99'; reason = '' }

        $script:DeskPilot.Settings.selectedProjectId | Should -Be 'p1'
        Get-TestOutboundText | Should -Match 'no project 99'
    }

    It 'switches on a tapped project button' {
        Invoke-DpIntercomCallback -Command @{ kind = 'callback'; callbackId = 'cb1'; text = 'p|p2' }

        $script:DeskPilot.Settings.selectedProjectId | Should -Be 'p2'
    }

    It 'says so when a project button points at something that has gone' {
        Invoke-DpIntercomCallback -Command @{ kind = 'callback'; callbackId = 'cb1'; text = 'p|gone' }

        $script:DeskPilot.Settings.selectedProjectId | Should -Be 'p1'
        Get-TestOutboundText | Should -Match 'could not find that one'
    }

    It 'points at /project new when there are no projects at all' {
        $script:DeskPilot = New-TestIntercomState

        Invoke-DpIntercomCommand -Command @{ kind = 'projects'; text = ''; reason = '' }

        Get-TestOutboundText | Should -Match 'no projects yet'
    }
}

Describe 'Intercom project creation' -Tag 'Unit' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $script:projectRoot = Join-Path $TestDrive 'work'
        New-Item -ItemType Directory -Path (Join-Path $script:projectRoot 'lab') -Force | Out-Null

        $projects = @(@{ id = 'p1'; name = 'Lab'; path = (Join-Path $script:projectRoot 'lab'); intercom = $true })
        $script:DeskPilot = New-TestIntercomState -Projects $projects -SelectedProjectId 'p1'
    }

    AfterEach { $script:DeskPilot = $null }

    It 'registers a folder that already exists and selects it' {
        $target = Join-Path $script:projectRoot 'notes'
        New-Item -ItemType Directory -Path $target -Force | Out-Null

        Invoke-DpIntercomCommand -Command @{ kind = 'project'; text = "new $target"; reason = '' }

        $added = @($script:DeskPilot.Settings.projects) | Where-Object { $_.path -eq $target }
        $added | Should -Not -BeNullOrEmpty
        $added.name | Should -Be 'notes'
        $script:DeskPilot.Settings.selectedProjectId | Should -Be $added.id
        Get-TestOutboundText | Should -Match 'Project added'
    }

    It 'never opts the new project into remote control' {
        # If a remote message could grant itself authority over a new folder, the
        # Project flag would be decorative: anyone holding the phone could point
        # DeskPilot anywhere and run there.
        $target = Join-Path $script:projectRoot 'fresh-flag'

        Invoke-DpIntercomCommand -Command @{ kind = 'project'; text = "new $target"; reason = '' }

        $added = @($script:DeskPilot.Settings.projects) | Where-Object { $_.path -eq $target }
        $added.intercom | Should -BeFalse
        (Test-DpIntercomProject -Settings $script:DeskPilot.Settings).allowed | Should -BeFalse
        Get-TestOutboundText | Should -Match 'Remote control is off for it'
    }

    It 'creates the last folder of the path when its parent exists' {
        $target = Join-Path $script:projectRoot 'fresh-created'

        Invoke-DpIntercomCommand -Command @{ kind = 'project'; text = "new $target"; reason = '' }

        Test-Path -LiteralPath $target -PathType Container | Should -BeTrue
        Get-TestOutboundText | Should -Match 'Folder created'
    }

    It 'refuses to build a whole tree when the parent does not exist' {
        $target = Join-Path $script:projectRoot 'missing' 'deep'

        Invoke-DpIntercomCommand -Command @{ kind = 'project'; text = "new $target"; reason = '' }

        Test-Path -LiteralPath $target | Should -BeFalse
        @($script:DeskPilot.Settings.projects).Count | Should -Be 1
        Get-TestOutboundText | Should -Match 'folder above it'
    }

    It 'refuses when no project has opted into remote control' {
        # Creating a folder is a change on disk, so it needs the same authority
        # running an instruction does.
        $script:DeskPilot.Settings.projects[0].intercom = $false
        $target = Join-Path $script:projectRoot 'fresh-refused'

        Invoke-DpIntercomCommand -Command @{ kind = 'project'; text = "new $target"; reason = '' }

        Test-Path -LiteralPath $target | Should -BeFalse
        @($script:DeskPilot.Settings.projects).Count | Should -Be 1
        @($script:DeskPilot.Intercom.Outbound.ToArray())[0].kind | Should -Be 'refused'
    }

    It 'refuses a path that is not a full one' {
        Invoke-DpIntercomCommand -Command @{ kind = 'project'; text = 'new some\relative\folder'; reason = '' }

        @($script:DeskPilot.Settings.projects).Count | Should -Be 1
        Get-TestOutboundText | Should -Match 'not a full path'
    }

    It 'refuses a whole drive' {
        $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($script:projectRoot))

        Invoke-DpIntercomCommand -Command @{ kind = 'project'; text = "new $root"; reason = '' }

        @($script:DeskPilot.Settings.projects).Count | Should -Be 1
        Get-TestOutboundText | Should -Match 'whole drive'
    }

    It 'refuses a file' {
        $file = Join-Path $script:projectRoot 'lab' 'readme.md'
        Set-Content -LiteralPath $file -Value 'x'

        Invoke-DpIntercomCommand -Command @{ kind = 'project'; text = "new $file"; reason = '' }

        @($script:DeskPilot.Settings.projects).Count | Should -Be 1
        Get-TestOutboundText | Should -Match 'a file, not a folder'
    }

    It 'switches to a folder that is already registered instead of refusing it' {
        # The duplicate is invisible from a phone, and switching is what was meant.
        $existing = Join-Path $script:projectRoot 'lab'
        $script:DeskPilot.Settings.selectedProjectId = $null

        Invoke-DpIntercomCommand -Command @{ kind = 'project'; text = "new $existing"; reason = '' }

        @($script:DeskPilot.Settings.projects).Count | Should -Be 1
        $script:DeskPilot.Settings.selectedProjectId | Should -Be 'p1'
        Get-TestOutboundText | Should -Match 'Switched project'
    }

    It 'asks which folder when /project new carries none' {
        Invoke-DpIntercomCommand -Command @{ kind = 'project'; text = 'new'; reason = '' }

        @($script:DeskPilot.Settings.projects).Count | Should -Be 1
        Get-TestOutboundText | Should -Match 'Which folder'
    }
}

Describe 'Intercom help and status name the new commands' -Tag 'Unit' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $script:DeskPilot = New-TestIntercomState
        $script:DeskPilot.Intercom.LastActivityUtc = [DateTime]::UtcNow
        $script:DeskPilot.Intercom.NextCheckInUtc = $null
        $script:DeskPilot.Intercom.PendingQuestion = $null
    }

    AfterEach { $script:DeskPilot = $null }

    It 'offers the agent and project commands in /help' {
        Invoke-DpIntercomCommand -Command @{ kind = 'help'; text = ''; reason = '' }

        $text = Get-TestOutboundText
        foreach ($command in @('/agents', '/agent 2', '/projects', '/project 2', '/project new')) {
            $text | Should -BeLike "*$command*"
        }
    }

    It 'reports the selected agent in /status' {
        $script:DeskPilot.Settings.selectedAgent = 'alpha.agent.md'

        $status = Get-DpIntercomStatus

        $status.lines -join "`n" | Should -Match 'Agent: alpha'
    }

    It 'reports the default agent when none is selected' {
        (Get-DpIntercomStatus).lines -join "`n" | Should -Match 'Agent: default'
    }
}
