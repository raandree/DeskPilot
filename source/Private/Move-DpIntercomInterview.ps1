function Move-DpIntercomInterview {
    <#
    .SYNOPSIS
        Advances a Questionnaire past the question just answered.
    .DESCRIPTION
        Sends the next question, or - once the last one is answered - serializes
        every collected answer into the single string the Ask-User bridge takes and
        releases the waiting Engine pipeline.

        The bridge is only ever called once per Questionnaire, at the end, exactly
        as the browser wizard does it. Answering step by step is a phone
        affordance, not a different contract.
    .OUTPUTS
        System.Boolean - whether the Questionnaire was completed and accepted.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Advances in-process Intercom state from an already-authorised answer; ShouldProcess is not meaningful on the accept thread.')]
    param()

    $state = $script:DeskPilot
    $intercom = $state.Intercom
    $pending = $intercom.PendingQuestion
    if (-not $pending) { return $false }

    $questions = @($pending.questions)
    $step = [int]$pending.step

    if (($step + 1) -lt $questions.Count) {
        $pending.step = $step + 1
        # A step that cannot be sent leaves the Engine parked on a question nobody
        # can see, so drop the whole thing rather than stall silently.
        if (-not (Send-DpIntercomQuestionStep)) { $intercom.PendingQuestion = $null }
        return $false
    }

    $answer = ConvertTo-DpQuestionnaireAnswer -Question $questions -Structured ([bool]$pending.structured)

    $bridge = $state.Engine.UserPromptBridge
    $accepted = $false
    if ($pending -and $bridge -and $state.TurnRunning) {
        $accepted = $bridge.SubmitAnswer([string]$pending.conversationId, [string]$pending.id, $answer)
    }

    $intercom.PendingQuestion = $null
    if ($accepted) {
        # Answering is activity, and it re-arms the one-shot stall warning so a
        # genuine stall after the answer is still reported.
        $intercom.LastActivityUtc = [DateTime]::UtcNow
        $intercom.StallNotified = $false
        $null = Send-DpIntercomMessage -Title 'Got it - the agent is continuing.' -Kind 'ack'
    }
    else {
        $null = Send-DpIntercomMessage -Title 'That question is no longer waiting for an answer.' -Line @(
            'Send a new instruction instead, or /status to see what is happening.'
        ) -Kind 'notice'
    }
    $accepted
}
