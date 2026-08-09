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
            Where-Object { -not [bool](Get-DpPropertyValue -InputObject $_ -Name @('archived') -Default $false) } |
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

    # Reporting must never be able to lose a finished job. Under Set-StrictMode
    # -Version Latest a missing hashtable key is a terminating error, so an
    # optional field read the wrong way used to throw here - after the Turn had
    # run - and the operator was told nothing at all.
    try {
        Send-DpIntercomTurnResult -Conversation $conversation -MessagesBefore $messagesBefore
    }
    catch {
        $reportError = Hide-DpIntercomSecret -Text "$_"
        Add-DpIntercomLog -Direction 'system' -Kind 'report-error' -Detail $reportError -Accepted $false
        $null = Send-DpIntercomMessage -Title 'The job finished.' -Line @(
            "Conversation: $([string]$conversation.title)",
            'Open DeskPilot to read the result.'
        ) -Kind 'done'
    }
}
