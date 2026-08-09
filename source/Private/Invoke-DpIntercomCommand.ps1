function Invoke-DpIntercomCommand {
    <#
    .SYNOPSIS
        Executes one normalized Intercom command.
    .DESCRIPTION
        Acts on a command record from ConvertFrom-DpIntercomUpdate. Every path
        either performs the action and acknowledges it, or refuses with a sentence
        a non-expert can act on.

        Two rules hold everywhere:

        A rejected chat is never answered. Replying would confirm the bot exists
        and turn it into a free oracle for anyone probing it; the rejection is
        counted and logged instead.

        Nothing here starts a Turn. A prompt becomes QueuedPrompt and the pump's
        final step runs it once the Engine Runspace is free, so a command arriving
        mid-Turn can never re-enter Invoke-DpTurn.
    .PARAMETER Command
        The command record from ConvertFrom-DpIntercomUpdate.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Drives in-process Intercom state from an already-authorised message; ShouldProcess is not meaningful on the accept thread.')]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Command
    )

    $state = $script:DeskPilot
    $intercom = $state.Intercom
    $intercom.Counters.received++

    if ($Command.kind -eq 'rejected') {
        $intercom.Counters.rejected++
        Add-DpIntercomLog -Direction 'in' -Kind 'rejected' -Detail $Command.reason -Accepted $false
        return
    }

    if ($Command.kind -eq 'ignore') {
        Add-DpIntercomLog -Direction 'in' -Kind 'ignored' -Detail $Command.reason -Accepted $false
        if ($Command.reason -like 'Unknown command*') {
            $null = Send-DpIntercomMessage -Title 'Unknown command' -Line @($Command.reason) -Kind 'notice'
        }
        return
    }

    $intercom.Counters.accepted++
    Add-DpIntercomLog -Direction 'in' -Kind $Command.kind -Detail $Command.text

    switch ($Command.kind) {
        'answer' {
            $pending = $intercom.PendingQuestion
            $bridge = $state.Engine.UserPromptBridge
            $accepted = $false
            if ($pending -and $bridge -and $state.TurnRunning) {
                $accepted = $bridge.SubmitAnswer([string]$pending.conversationId, [string]$pending.id, [string]$Command.text)
            }
            if ($accepted) {
                $intercom.PendingQuestion = $null
                $null = Send-DpIntercomMessage -Title 'Got it - the agent is continuing.' -Kind 'ack'
            }
            else {
                $intercom.PendingQuestion = $null
                $null = Send-DpIntercomMessage -Title 'That question is no longer waiting for an answer.' -Line @('Send a new instruction instead, or /status to see what is happening.') -Kind 'notice'
            }
        }

        'stop' {
            if (-not $state.TurnRunning) {
                $null = Send-DpIntercomMessage -Title 'Nothing is running.' -Kind 'notice'
                return
            }
            $state.CancelRequested = $true
            if ($state.Engine.UserPromptBridge) { $state.Engine.UserPromptBridge.Cancel() }
            $intercom.PendingQuestion = $null
            $null = Send-DpIntercomMessage -Title 'Stopping the job.' -Kind 'ack'
        }

        'status' {
            $status = Get-DpIntercomStatus
            $null = Send-DpIntercomMessage -Title $status.title -Line $status.lines -Kind 'status-reply'
        }

        'help' {
            $null = Send-DpIntercomMessage -Title 'DeskPilot Intercom' -Line @(
                'Reply to a question message to answer it.',
                'Send any other text to give the agent a new instruction.',
                '/status - what is happening right now',
                '/chats - list your conversations',
                '/chat 3 - switch to conversation 3',
                '/new - start a fresh conversation',
                '/new <text> - start a fresh conversation and do this',
                '/archive 3 - hide conversation 3 from the list',
                '/delete 3 - remove it for good (asks first)',
                '/stop - stop the running job',
                '/steer <text> - stop the job, then do this instead',
                '/help - this list'
            ) -Kind 'help'
        }

        'chats' {
            $chats = @(Get-DpIntercomChatList)
            if ($chats.Count -eq 0) {
                $null = Send-DpIntercomMessage -Title 'There are no conversations yet.' -Line @('Send /new to start one.') -Kind 'chats'
                return
            }
            # Remember what each number pointed at: the list is ordered by last
            # activity, so running a Turn reorders it under the operator's feet.
            $intercom.ChatIndex = @($chats | ForEach-Object { $_.id })
            $lines = @($chats | ForEach-Object {
                    '{0}. {1}{2}' -f $_.number, $_.title, $(if ($_.current) { '  <- current' } else { '' })
                })
            $null = Send-DpIntercomMessage -Title 'Your conversations' -Line ($lines + @('', 'Send /chat 2 to switch, or /new to start one.')) -Kind 'chats'
        }

        'chat' {
            if ([string]::IsNullOrWhiteSpace($Command.text)) {
                $null = Send-DpIntercomMessage -Title 'Which one?' -Line @('Send /chats to see the list, then /chat 2.') -Kind 'notice'
                return
            }
            $choice = 0
            if (-not [int]::TryParse($Command.text.Trim(), [ref]$choice)) {
                $null = Send-DpIntercomMessage -Title 'That is not a number from the list.' -Line @('Send /chats to see it again.') -Kind 'notice'
                return
            }
            $resolved = Resolve-DpIntercomChat -Number $choice
            if (-not $resolved.ok) {
                $null = Send-DpIntercomMessage -Title 'I could not find that one.' -Line @($resolved.message) -Kind 'notice'
                return
            }
            $intercom.ConversationId = [string]$resolved.conversation.id
            $null = Send-DpIntercomMessage -Title 'Switched.' -Line @(
                "Now working in: $([string]$resolved.conversation.title)",
                'Send an instruction, or /chats to switch again.'
            ) -Kind 'chat'
        }

        'archive' {
            $choice = 0
            if (-not [int]::TryParse(([string]$Command.text).Trim(), [ref]$choice)) {
                $null = Send-DpIntercomMessage -Title 'Which one?' -Line @('Send /chats to see the list, then /archive 2.') -Kind 'notice'
                return
            }
            $resolved = Resolve-DpIntercomChat -Number $choice
            if (-not $resolved.ok) {
                $null = Send-DpIntercomMessage -Title 'I could not find that one.' -Line @($resolved.message) -Kind 'notice'
                return
            }
            $resolved.conversation.archived = $true
            Set-DpIntercomChatRemoved -ConversationId ([string]$resolved.conversation.id)
            $null = Send-DpIntercomMessage -Title 'Archived.' -Line @(
                "Hidden from the list: $([string]$resolved.conversation.title)",
                'It is still in DeskPilot under "Show archived".'
            ) -Kind 'archive'
        }

        'delete' {
            $parts = ([string]$Command.text).Trim() -split '\s+', 2
            $choice = 0
            if (-not [int]::TryParse($parts[0], [ref]$choice)) {
                $null = Send-DpIntercomMessage -Title 'Which one?' -Line @('Send /chats to see the list, then /delete 2.') -Kind 'notice'
                return
            }
            $resolved = Resolve-DpIntercomChat -Number $choice
            if (-not $resolved.ok) {
                $null = Send-DpIntercomMessage -Title 'I could not find that one.' -Line @($resolved.message) -Kind 'notice'
                return
            }
            $title = [string]$resolved.conversation.title
            # Deleting is the one irreversible thing Intercom can do, and a phone
            # is where a mistyped number is most likely, so it takes two messages.
            if ($parts.Count -lt 2 -or $parts[1].Trim().ToLowerInvariant() -ne 'confirm') {
                $null = Send-DpIntercomMessage -Title 'This cannot be undone.' -Line @(
                    "About to delete: $title",
                    "Send /delete $choice confirm to go ahead, or /archive $choice to just hide it."
                ) -Kind 'notice'
                return
            }
            $null = $state.Conversations.Remove([string]$resolved.conversation.id)
            Set-DpIntercomChatRemoved -ConversationId ([string]$resolved.conversation.id)
            $null = Send-DpIntercomMessage -Title 'Deleted.' -Line @($title) -Kind 'delete'
        }

        'steer' {
            if ([string]::IsNullOrWhiteSpace($Command.text)) {
                $null = Send-DpIntercomMessage -Title 'Add the new instruction after /steer.' -Kind 'notice'
                return
            }
            $decision = Test-DpIntercomProject -Settings $state.Settings
            if (-not $decision.allowed) {
                $null = Send-DpIntercomMessage -Title 'I cannot do that from here.' -Line @($decision.reason) -Kind 'refused'
                return
            }
            if ($state.TurnRunning) {
                $state.CancelRequested = $true
                if ($state.Engine.UserPromptBridge) { $state.Engine.UserPromptBridge.Cancel() }
                $intercom.PendingQuestion = $null
            }
            $intercom.QueuedPrompt = [string]$Command.text
            $null = Send-DpIntercomMessage -Title 'Stopping, then doing that instead.' -Kind 'ack'
        }

        'new' {
            if ($state.TurnRunning) {
                $null = Send-DpIntercomMessage -Title 'A job is running.' -Line @('Send /stop first, or /steer <text> to replace it.') -Kind 'notice'
                return
            }
            # A bare /new only moves where Intercom is pointing, so it needs no
            # Project permission; only running work in the Project does.
            $hasWork = -not [string]::IsNullOrWhiteSpace($Command.text)
            if ($hasWork) {
                $decision = Test-DpIntercomProject -Settings $state.Settings
                if (-not $decision.allowed) {
                    $null = Send-DpIntercomMessage -Title 'I cannot do that from here.' -Line @($decision.reason) -Kind 'refused'
                    return
                }
            }
            $conversation = New-DpConversation -Model $state.Settings.model
            $state.Conversations[$conversation.id] = $conversation
            if ($state.DataDir) { Save-DpConversationStore -Store $state.Conversations -Directory $state.DataDir }
            $intercom.ConversationId = $conversation.id
            $intercom.ChatIndex = @()
            if ($hasWork) {
                $intercom.QueuedPrompt = [string]$Command.text
                $null = Send-DpIntercomMessage -Title 'New conversation started. Working on it.' -Kind 'ack'
            }
            else {
                $null = Send-DpIntercomMessage -Title 'New conversation started.' -Line @('Send an instruction whenever you are ready.') -Kind 'ack'
            }
        }

        'prompt' {
            $decision = Test-DpIntercomProject -Settings $state.Settings
            if (-not $decision.allowed) {
                $null = Send-DpIntercomMessage -Title 'I cannot do that from here.' -Line @($decision.reason) -Kind 'refused'
                return
            }
            if ($intercom.QueuedPrompt) {
                $null = Send-DpIntercomMessage -Title 'One instruction is already queued.' -Line @('Send /stop if you want to replace what is running.') -Kind 'notice'
                return
            }
            $intercom.QueuedPrompt = [string]$Command.text
            if ($state.TurnRunning) {
                $null = Send-DpIntercomMessage -Title 'Queued - it will run when the current job finishes.' -Kind 'ack'
            }
            else {
                $null = Send-DpIntercomMessage -Title 'Got it, working on it.' -Kind 'ack'
            }
        }
    }
}
