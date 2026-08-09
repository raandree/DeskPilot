function Submit-DpIntercomAnswer {
    <#
    .SYNOPSIS
        Hands an answer to the Ask-User question the Engine is blocked on.
    .DESCRIPTION
        The single path an answer takes, whether the operator replied with text or
        tapped a button. Sharing it matters: the acknowledgement, the "that question
        has gone" wording, and the clearing of the pending question all have to be
        identical, or the two routes drift into behaving differently for the same
        act.
    .PARAMETER Answer
        The answer text to submit.
    .OUTPUTS
        System.Boolean - whether the waiting pipeline accepted it.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Releases an already-authorised answer on the accept thread; ShouldProcess cannot prompt over Telegram.')]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Answer
    )

    $state = $script:DeskPilot
    $intercom = $state.Intercom

    $pending = $intercom.PendingQuestion
    $bridge = $state.Engine.UserPromptBridge
    $accepted = $false
    if ($pending -and $bridge -and $state.TurnRunning) {
        $accepted = $bridge.SubmitAnswer([string]$pending.conversationId, [string]$pending.id, $Answer)
    }

    $intercom.PendingQuestion = $null
    if ($accepted) {
        $null = Send-DpIntercomMessage -Title 'Got it - the agent is continuing.' -Kind 'ack'
    }
    else {
        $null = Send-DpIntercomMessage -Title 'That question is no longer waiting for an answer.' -Line @('Send a new instruction instead, or /status to see what is happening.') -Kind 'notice'
    }
    $accepted
}
