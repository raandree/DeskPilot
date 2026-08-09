#requires -Version 7.0

BeforeAll {
    # The module runs under Set-StrictMode -Version Latest (source/Prefix.ps1),
    # where reading a missing hashtable key is a terminating error rather than
    # $null. Tests that run without it validate different semantics than
    # production.
    Set-StrictMode -Version Latest
    $privateRoot = Join-Path $PSScriptRoot '..' '..' 'source' 'Private'
    Get-ChildItem -Path $privateRoot -Filter '*.ps1' | ForEach-Object { . $_.FullName }

    function New-TestCheckpointConversation {
        [CmdletBinding()]
        [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'A test helper that builds an in-memory Conversation; it changes nothing.')]
        param([string]$Sha = 'abc123', [string]$Root = 'C:\proj')

        @{
            id       = 'c1'
            title    = 'Test'
            messages = [System.Collections.Generic.List[object]]@(
                @{ id = 'u1'; role = 'user'; text = 'first' }
                @{ id = 'a1'; role = 'assistant'; text = 'ok'; activity = @{ filesWritten = @() } }
                @{ id = 'u2'; role = 'user'; text = 'second prompt'; checkpoint = @{ sha = $Sha; root = $Root; createdUtc = '2026-01-01T00:00:00.0000000Z' } }
                @{ id = 'a2'; role = 'assistant'; text = 'done'; activity = @{ filesWritten = @("$Root\src\one.ps1", "$Root\src\two.ps1") } }
            )
            history  = [System.Collections.Generic.List[object]]@()
        }
    }
}

Describe 'Get-DpCheckpointSha' -Tag 'Unit' {
    It 'collects every checkpoint commit in the store' {
        $script:DeskPilot = @{ Conversations = @{ c1 = (New-TestCheckpointConversation -Sha 'sha-one') } }
        Get-DpCheckpointSha | Should -Be @('sha-one')
    }

    It 'returns nothing when no message carries a checkpoint' {
        $conversation = New-TestCheckpointConversation
        $conversation.messages[2].Remove('checkpoint')
        $script:DeskPilot = @{ Conversations = @{ c1 = $conversation } }
        @(Get-DpCheckpointSha).Count | Should -Be 0
    }

    It 'keeps only the checkpoints taken in the given project' {
        $script:DeskPilot = @{
            Conversations = @{
                c1 = (New-TestCheckpointConversation -Sha 'here' -Root 'C:\proj')
                c2 = (New-TestCheckpointConversation -Sha 'elsewhere' -Root 'C:\other')
            }
        }
        Get-DpCheckpointSha -Root 'C:\proj' | Should -Be @('here')
    }

    It 'survives an empty store' {
        $script:DeskPilot = @{ Conversations = @{} }
        @(Get-DpCheckpointSha -Root 'C:\proj').Count | Should -Be 0
    }
}

Describe 'Restore-DpCheckpoint' -Tag 'Unit' {
    BeforeEach {
        $script:DeskPilot = @{ Conversations = @{}; Changes = @{} }
    }

    It 'drops the message and everything after it, and hands back the prompt' {
        $conversation = New-TestCheckpointConversation
        Mock Invoke-DpChangeUndo { @{ restored = @('src\one.ps1'); removed = @('src\two.ps1'); skipped = @(); kept = @(); error = $null } }
        Mock Remove-DpChangeEntry { }

        $result = Restore-DpCheckpoint -Conversation $conversation -MessageId 'u2' -Root 'C:\proj'

        $result.ok | Should -BeTrue
        $result.prompt | Should -Be 'second prompt'
        @($conversation.messages).Count | Should -Be 2
        @($conversation.messages)[-1].id | Should -Be 'a1'
    }

    It 'puts back only the files the discarded turns wrote' {
        $conversation = New-TestCheckpointConversation -Sha 'snap'
        $script:captured = $null
        Mock Invoke-DpChangeUndo { $script:captured = $Entries; @{ restored = @('src\one.ps1'); removed = @(); skipped = @(); kept = @(); error = $null } }
        Mock Remove-DpChangeEntry { }

        $result = Restore-DpCheckpoint -Conversation $conversation -MessageId 'u2' -Root 'C:\proj'

        $result.filesTried | Should -BeTrue
        @($script:captured).Count | Should -Be 2
        @($script:captured)[0].snapshotSha | Should -Be 'snap'
        @($script:captured).rel | Should -Contain 'src/one.ps1'
        @($script:captured).rel | Should -Contain 'src/two.ps1'
        $result.restored | Should -Be @('src\one.ps1')
    }

    It 'clears the pending changes those turns left behind' {
        $conversation = New-TestCheckpointConversation
        Mock Invoke-DpChangeUndo { @{ restored = @(); removed = @(); skipped = @(); kept = @(); error = $null } }
        Mock Remove-DpChangeEntry { }

        $null = Restore-DpCheckpoint -Conversation $conversation -MessageId 'u2' -Root 'C:\proj'

        Should -Invoke Remove-DpChangeEntry -Times 1 -Exactly
    }

    It 'refuses a message that is not in the conversation' {
        $conversation = New-TestCheckpointConversation
        $result = Restore-DpCheckpoint -Conversation $conversation -MessageId 'nope' -Root 'C:\proj'

        $result.ok | Should -BeFalse
        $result.error | Should -Match 'no longer'
        @($conversation.messages).Count | Should -Be 4
    }

    It 'refuses an assistant message' {
        $conversation = New-TestCheckpointConversation
        $result = Restore-DpCheckpoint -Conversation $conversation -MessageId 'a2' -Root 'C:\proj'

        $result.ok | Should -BeFalse
        $result.error | Should -Match 'message you sent'
        @($conversation.messages).Count | Should -Be 4
    }

    It 'still truncates when the project has no snapshot' {
        $conversation = New-TestCheckpointConversation
        $conversation.messages[2].checkpoint.sha = ''
        Mock Invoke-DpChangeUndo { throw 'must not be called' }
        Mock Remove-DpChangeEntry { }

        $result = Restore-DpCheckpoint -Conversation $conversation -MessageId 'u2' -Root 'C:\proj'

        $result.ok | Should -BeTrue
        $result.filesTried | Should -BeFalse
        @($conversation.messages).Count | Should -Be 2
    }

    It 'leaves the files alone when asked to' {
        $conversation = New-TestCheckpointConversation
        Mock Invoke-DpChangeUndo { throw 'must not be called' }
        Mock Remove-DpChangeEntry { }

        $result = Restore-DpCheckpoint -Conversation $conversation -MessageId 'u2' -Root 'C:\proj' -SkipFiles

        $result.ok | Should -BeTrue
        $result.filesTried | Should -BeFalse
        Should -Invoke Invoke-DpChangeUndo -Times 0 -Exactly
    }

    It 'keeps the conversation intact when the restore fails' {
        $conversation = New-TestCheckpointConversation
        Mock Invoke-DpChangeUndo { @{ restored = @(); removed = @(); skipped = @(); kept = @(); error = 'git exploded' } }
        Mock Remove-DpChangeEntry { }

        $result = Restore-DpCheckpoint -Conversation $conversation -MessageId 'u2' -Root 'C:\proj'

        $result.ok | Should -BeFalse
        $result.error | Should -Be 'git exploded'
        @($conversation.messages).Count | Should -Be 4
    }

    It 'works without a project folder' {
        $conversation = New-TestCheckpointConversation
        Mock Invoke-DpChangeUndo { throw 'must not be called' }
        Mock Remove-DpChangeEntry { throw 'must not be called' }

        $result = Restore-DpCheckpoint -Conversation $conversation -MessageId 'u2' -Root ''

        $result.ok | Should -BeTrue
        $result.prompt | Should -Be 'second prompt'
    }
}
