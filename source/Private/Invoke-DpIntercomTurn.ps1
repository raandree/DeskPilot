function Invoke-DpIntercomTurn {
    <#
    .SYNOPSIS
        Runs a Turn requested from the phone and reports the outcome.
    .DESCRIPTION
        Resolves the bound Conversation (creating one on first use), runs the Turn
        with the SSE stream pointed at Stream.Null - no browser is attached, but
        the Conversation, Usage, Activity and pending change set are updated
        exactly as for a local Turn - then pushes the result.

        Called only from the pump's final step, on the accept loop, with no Turn
        running. Invoke-DpTurn keeps servicing the listener while it runs, so the
        browser stays responsive and /stop still lands.

        The outcome message is composed from structured fields DeskPilot owns. The
        agent's answer text is included only when sendFinalAnswer is on, and is
        bounded and split by Format-DpIntercomMessage.
    .PARAMETER Prompt
        The prompt received from the phone.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Driven by the pump from an already-authorised message; ShouldProcess is not meaningful on the accept thread.')]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Prompt
    )

    $state = $script:DeskPilot
    $intercom = $state.Intercom

    $conversation = $null
    if ($intercom.ConversationId) { $conversation = $state.Conversations[$intercom.ConversationId] }
    if (-not $conversation) {
        $conversation = @($state.Conversations.Values) |
            Where-Object { -not $_.archived } |
            Sort-Object -Property updatedUtc -Descending |
            Select-Object -First 1
    }
    if (-not $conversation) {
        $conversation = New-DpConversation -Model $state.Settings.model
        $state.Conversations[$conversation.id] = $conversation
    }
    $intercom.ConversationId = [string]$conversation.id

    $messagesBefore = $conversation.messages.Count
    $intercom.LastActivityUtc = [DateTime]::UtcNow
    $intercom.StallNotified = $false

    Add-DpIntercomLog -Direction 'system' -Kind 'turn-start' -Detail $Prompt

    try {
        Invoke-DpTurn -Conversation $conversation -Prompt $Prompt -Stream ([System.IO.Stream]::Null)
    }
    catch {
        $failure = Hide-DpIntercomSecret -Text "$_"
        Add-DpIntercomLog -Direction 'system' -Kind 'turn-error' -Detail $failure -Accepted $false
        $null = Send-DpIntercomMessage -Title 'The job failed to run.' -Line @($failure) -Kind 'failed'
        return
    }
    finally {
        $intercom.StallNotified = $false
    }

    if (-not [bool]$state.Settings.intercom.notifyOnDone) { return }

    $last = if ($conversation.messages.Count -gt 0) { $conversation.messages[$conversation.messages.Count - 1] } else { $null }

    # Invoke-DpTurn records the user Message first and only adds an assistant
    # Message when the Engine answered, so a trailing user Message means the Turn
    # failed before producing anything.
    if (-not $last -or [string]$last.role -ne 'assistant' -or $conversation.messages.Count -le $messagesBefore) {
        $null = Send-DpIntercomMessage -Title 'The job failed.' -Line @(
            "Conversation: $([string]$conversation.title)",
            'Open DeskPilot to see what went wrong.'
        ) -Kind 'failed'
        return
    }

    if ([bool]$last.stopped) {
        $null = Send-DpIntercomMessage -Title 'The job was stopped.' -Line @("Conversation: $([string]$conversation.title)") -Kind 'stopped'
        return
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("Conversation: $([string]$conversation.title)")
    $lines.Add("Took: $([int]([double]$last.durationMs / 1000)) s")
    if ($last.activity) {
        $written = @($last.activity.filesWritten).Count
        $commands = @($last.activity.commandsRun).Count
        if ($written -gt 0) { $lines.Add("Files changed: $written") }
        if ($commands -gt 0) { $lines.Add("Commands run: $commands") }
    }

    $body = $null
    if ([bool]$state.Settings.intercom.sendFinalAnswer) { $body = [string]$last.text }

    $sendParams = @{
        Title = 'Done.'
        Line  = @($lines.ToArray())
        Kind  = 'done'
    }
    if (-not [string]::IsNullOrWhiteSpace($body)) { $sendParams.Body = $body }
    $null = Send-DpIntercomMessage @sendParams
}
