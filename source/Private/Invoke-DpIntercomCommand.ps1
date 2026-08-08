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
                '/stop - stop the running job',
                '/steer <text> - stop the job, then do this instead',
                '/new <text> - start a fresh conversation and do this',
                '/help - this list'
            ) -Kind 'help'
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
            if ([string]::IsNullOrWhiteSpace($Command.text)) {
                $null = Send-DpIntercomMessage -Title 'Add the instruction after /new.' -Kind 'notice'
                return
            }
            $decision = Test-DpIntercomProject -Settings $state.Settings
            if (-not $decision.allowed) {
                $null = Send-DpIntercomMessage -Title 'I cannot do that from here.' -Line @($decision.reason) -Kind 'refused'
                return
            }
            if ($state.TurnRunning) {
                $null = Send-DpIntercomMessage -Title 'A job is running.' -Line @('Send /stop first, or /steer <text> to replace it.') -Kind 'notice'
                return
            }
            $conversation = New-DpConversation -Model $state.Settings.model
            $state.Conversations[$conversation.id] = $conversation
            if ($state.DataDir) { Save-DpConversationStore -Store $state.Conversations -Directory $state.DataDir }
            $intercom.ConversationId = $conversation.id
            $intercom.QueuedPrompt = [string]$Command.text
            $null = Send-DpIntercomMessage -Title 'New conversation started. Working on it.' -Kind 'ack'
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
