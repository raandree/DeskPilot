function Update-DpIntercomState {
    <#
    .SYNOPSIS
        Advances Intercom by one non-blocking step.
    .DESCRIPTION
        The Intercom pump. It reaps whatever finished, starts whatever is due, and
        returns - it never waits on the network, and it never throws into its
        caller.

        It runs from two places, and both are necessary:

          * The accept loop's idle tick, so Intercom works between Turns and can
            start a Turn the operator asked for from their phone.
          * Invoke-DpPendingRequest, so it also runs *during* a Turn - which is
            exactly when the agent asks a question and when /stop has to land.

        Only the accept-loop caller passes -AllowTurn. Starting a Turn is the last
        thing this function does, so a command that arrives mid-Turn is queued
        rather than re-entering Invoke-DpTurn.
    .PARAMETER AllowTurn
        Permit the queued prompt to run. Only the accept loop may pass this.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'A pump tick driven by the accept loop; ShouldProcess would make it unusable.')]
    param(
        [switch]$AllowTurn
    )

    $state = $script:DeskPilot
    if (-not $state) { return }
    $intercom = $state.Intercom
    if (-not $intercom -or -not $intercom.Client) { return }

    $settings = $state.Settings.intercom
    $chatId = if ($settings) { [string]$settings.chatId } else { '' }

    # A pairing window lets the poller run before a chat is allow-listed, purely
    # so the operator can discover their own chat id. It expires on its own: an
    # allow-list that is open indefinitely is not an allow-list.
    $pairing = $intercom.Pairing
    if ($pairing.active) {
        $expired = (-not $pairing.startedUtc) -or ([DateTime]::UtcNow - [DateTime]$pairing.startedUtc).TotalMinutes -ge 5
        if ($expired -or -not [string]::IsNullOrWhiteSpace($chatId)) {
            $pairing.active = $false
            $pairing.startedUtc = $null
            if ($expired) { Add-DpIntercomLog -Direction 'system' -Kind 'pairing' -Detail 'The pairing window closed.' }
        }
    }
    $isPairing = [bool]$pairing.active -and [string]::IsNullOrWhiteSpace($chatId)

    $shouldRun = [bool]$settings -and [bool]$settings.enabled -and
        $intercom.TokenConfigured -and (-not [string]::IsNullOrWhiteSpace($chatId) -or $isPairing)

    try {
        # 1. Enable / disable transitions.
        if ($shouldRun -and -not $intercom.Running) {
            $intercom.Running = $true
            $intercom.StartedUtc = [DateTime]::UtcNow
            $intercom.StatusMessageId = 0
            $intercom.LastHeartbeatUtc = $null
            # During pairing the backlog is exactly what we want to see: those
            # messages execute nothing, and the one the operator already sent is
            # usually the fastest way for them to recognise their own chat.
            $intercom.Priming = -not $isPairing
            $intercom.LastError = ''
            Add-DpIntercomLog -Direction 'system' -Kind 'enabled' -Detail $(if ($isPairing) { 'Listening for a pairing message.' } else { 'Intercom is on.' })
            $null = Send-DpIntercomMessage -Title 'DeskPilot Intercom is on.' -Line @(
                "Machine: $([Environment]::MachineName)",
                'Send /help for the command list.'
            ) -Kind 'enabled'
        }
        elseif (-not $shouldRun -and $intercom.Running) {
            $intercom.Running = $false
            $intercom.PollTask = $null
            $intercom.PendingQuestion = $null
            $intercom.QueuedPrompt = $null
            $intercom.Outbound.Clear()
            $intercom.StatusMessageId = 0
            Add-DpIntercomLog -Direction 'system' -Kind 'disabled' -Detail 'Intercom is off.'
        }
        if (-not $intercom.Running) { return }

        # 2. Reap a finished send, capturing the message id when the record asked
        #    for it (the question nonce, or the live status message).
        if ($intercom.SendTask -and $intercom.SendTask.IsCompleted) {
            $record = $intercom.SendRecord
            $response = Receive-DpTelegramResponse -Task $intercom.SendTask
            $intercom.SendTask = $null
            $intercom.SendRecord = $null
            if ($response.ok) {
                $intercom.Counters.sent++
                $messageId = [long](Get-DpPropertyValue -InputObject $response.result -Name @('message_id') -Default 0)
                if ($record.capture -eq 'question' -and $intercom.PendingQuestion) {
                    $intercom.PendingQuestion.messageId = $messageId
                }
                elseif ($record.capture -eq 'status' -and $messageId -gt 0) {
                    $intercom.StatusMessageId = $messageId
                }
                if (-not $record.edit) {
                    Add-DpIntercomLog -Direction 'out' -Kind $record.kind -Detail $record.text
                }
            }
            else {
                $intercom.Counters.errors++
                $intercom.LastError = $response.error
                # An edit fails when the status message was deleted or is too old.
                # Drop the id so the next heartbeat posts a fresh one.
                if ($record.edit) { $intercom.StatusMessageId = 0 }
                Add-DpIntercomLog -Direction 'out' -Kind 'error' -Detail $response.error -Accepted $false
            }
        }

        # 3. Start the next queued send. One at a time, so ordering is preserved.
        if (-not $intercom.SendTask -and $intercom.Outbound.Count -gt 0) {
            $record = $intercom.Outbound.Dequeue()
            $useEdit = $record.edit -and $intercom.StatusMessageId -gt 0
            $operation = if ($useEdit) { 'editMessageText' } else { 'sendMessage' }
            $payload = @{
                chat_id                  = $chatId
                text                     = [string]$record.text
                disable_web_page_preview = $true
            }
            if ($useEdit) { $payload.message_id = $intercom.StatusMessageId }
            if ($record.edit -and -not $useEdit) { $record.capture = 'status' }
            try {
                $intercom.SendTask = Invoke-DpTelegramRequest -Client $intercom.Client -Token $intercom.Token -Operation $operation -Payload $payload
                $intercom.SendRecord = $record
            }
            catch {
                $intercom.Counters.errors++
                $intercom.LastError = Hide-DpIntercomSecret -Text "$_"
                $intercom.SendTask = $null
                $intercom.SendRecord = $null
            }
        }

        # 4. Reap a finished poll and act on what arrived.
        if ($intercom.PollTask -and $intercom.PollTask.IsCompleted) {
            $response = Receive-DpTelegramResponse -Task $intercom.PollTask
            $intercom.PollTask = $null
            $intercom.LastPollUtc = [DateTime]::UtcNow
            if ($response.ok) {
                $intercom.LastError = ''
                $updates = @($response.result)
                $highest = 0
                foreach ($update in $updates) {
                    $updateId = [long](Get-DpPropertyValue -InputObject $update -Name @('update_id') -Default 0)
                    if ($updateId -gt $highest) { $highest = $updateId }
                }
                if ($highest -gt 0) { $intercom.Offset = $highest + 1 }

                if ($intercom.Priming) {
                    # Everything queued while DeskPilot was not running is discarded.
                    # Executing a command the operator sent an hour ago, on startup,
                    # would be a genuinely dangerous surprise.
                    $intercom.Priming = $false
                    if ($updates.Count -gt 0) {
                        Add-DpIntercomLog -Direction 'system' -Kind 'primed' -Detail "Discarded $($updates.Count) message(s) that arrived while DeskPilot was not running."
                    }
                }
                else {
                    $pendingMessageId = 0
                    if ($intercom.PendingQuestion) { $pendingMessageId = [long]$intercom.PendingQuestion.messageId }
                    foreach ($update in $updates) {
                        $commandParams = @{
                            Update                   = $update
                            AllowedChatId            = $chatId
                            PendingQuestionMessageId = $pendingMessageId
                        }
                        $command = ConvertFrom-DpIntercomUpdate @commandParams
                        # While pairing, chatId is empty, so every command comes back
                        # 'rejected' and nothing executes. Keep the sender as a
                        # candidate for the operator to confirm, and stop there.
                        if ($isPairing) {
                            Add-DpIntercomPairingCandidate -Command $command
                            continue
                        }
                        Invoke-DpIntercomCommand -Command $command
                        if ($intercom.PendingQuestion) { $pendingMessageId = [long]$intercom.PendingQuestion.messageId } else { $pendingMessageId = 0 }
                    }
                }
            }
            else {
                $intercom.Counters.errors++
                $intercom.LastError = $response.error
                Add-DpIntercomLog -Direction 'system' -Kind 'poll-error' -Detail $response.error -Accepted $false
            }
        }

        # 5. Start the next long poll. Telegram holds the request open until a
        #    message arrives, so this is both instant and nearly free when idle.
        if (-not $intercom.PollTask) {
            $pollPayload = if ($intercom.Priming) {
                @{ offset = -1; timeout = 0; limit = 1; allowed_updates = @('message') }
            }
            else {
                @{ offset = $intercom.Offset; timeout = 20; limit = 10; allowed_updates = @('message') }
            }
            try {
                $intercom.PollTask = Invoke-DpTelegramRequest -Client $intercom.Client -Token $intercom.Token -Operation 'getUpdates' -Payload $pollPayload
            }
            catch {
                $intercom.Counters.errors++
                $intercom.LastError = Hide-DpIntercomSecret -Text "$_"
                $intercom.PollTask = $null
            }
        }

        # Pairing ends here: there is no chat to message, no heartbeat to send and
        # no Turn to run until the operator has confirmed who they are.
        if ($isPairing) { return }

        $now = [DateTime]::UtcNow

        # 6. Heartbeat: refresh the live status message. This is an edit, so it
        #    costs no notification - and when the machine dies it simply stops,
        #    leaving a stated deadline in the past for the operator to read.
        $heartbeatMinutes = [int]$settings.heartbeatMinutes
        if ($heartbeatMinutes -lt 1) { $heartbeatMinutes = 5 }
        if (-not $intercom.LastHeartbeatUtc -or ($now - $intercom.LastHeartbeatUtc).TotalMinutes -ge $heartbeatMinutes) {
            $intercom.LastHeartbeatUtc = $now
            # Stated before the message is built, so the message can quote it.
            $intercom.NextCheckInUtc = $now.AddMinutes($heartbeatMinutes + 1)
            $status = Get-DpIntercomStatus
            $null = Send-DpIntercomMessage -Title $status.title -Line $status.lines -Kind 'status' -Capture 'status'
        }

        # 7. Stall watchdog: a Turn that has produced nothing for a while. Sent
        #    once per Turn, so a long quiet build cannot turn into a flood.
        $stallMinutes = [int]$settings.stallMinutes
        if ($stallMinutes -lt 1) { $stallMinutes = 5 }
        if ($state.TurnRunning -and -not $intercom.StallNotified -and
            ($now - $intercom.LastActivityUtc).TotalMinutes -ge $stallMinutes) {
            $intercom.StallNotified = $true
            $null = Send-DpIntercomMessage -Title 'The agent has gone quiet.' -Line @(
                "No activity for $stallMinutes minutes.",
                'It may be running something long, or it may be stuck.',
                'Send /stop to end it, or /status for details.'
            ) -Kind 'stalled'
        }

        # 8. Expire a forwarded question nobody answered.
        if ($intercom.PendingQuestion) {
            $questionTimeout = [int]$settings.questionTimeoutMinutes
            if ($questionTimeout -lt 1) { $questionTimeout = 60 }
            if (($now - [DateTime]$intercom.PendingQuestion.askedUtc).TotalMinutes -ge $questionTimeout) {
                $intercom.PendingQuestion = $null
                $null = Send-DpIntercomMessage -Title 'That question has expired.' -Line @('Answer by replying to a question message within the time stated.') -Kind 'expired'
            }
        }

        # 9. Run the queued prompt. Last, and only from the accept loop, so this
        #    can never re-enter a Turn that is already running.
        if ($AllowTurn -and $intercom.QueuedPrompt -and -not $state.TurnRunning) {
            $prompt = [string]$intercom.QueuedPrompt
            $intercom.QueuedPrompt = $null
            Invoke-DpIntercomTurn -Prompt $prompt
        }
    }
    catch {
        # The pump runs on the accept thread. An escape here would take the whole
        # Host Server down, so every failure is recorded and swallowed.
        $intercom.Counters.errors++
        $intercom.LastError = Hide-DpIntercomSecret -Text "$_"
        Add-DpIntercomLog -Direction 'system' -Kind 'error' -Detail $intercom.LastError -Accepted $false
    }
}
