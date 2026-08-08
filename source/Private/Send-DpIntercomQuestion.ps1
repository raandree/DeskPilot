function Send-DpIntercomQuestion {
    <#
    .SYNOPSIS
        Forwards a pending Ask-User question to the phone.
    .DESCRIPTION
        Called from the Turn loop the moment DeskPilot publishes an Ask-User
        request to the browser, so the phone and the window learn about it
        together. The Telegram message id that carries the question becomes the
        answer nonce: only a reply to that exact message is accepted, so there is
        nothing for the operator to type at a bus stop.

        The question text is authored by the agent, and forwarding it verbatim is
        the one accepted exception to composing messages from structured fields
        (spec 110, risk A1). The exception is bounded by the Project gate below: a
        Project that is not Intercom-enabled never forwards anything, so it can
        never become an outbound channel.
    .PARAMETER RequestId
        The bridge's question id, matched when the answer is submitted.
    .PARAMETER ConversationId
        The Conversation the question belongs to.
    .PARAMETER Questionnaire
        The normalized Questionnaire from ConvertTo-DpQuestionnaire.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$RequestId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ConversationId,

        [Parameter(Mandatory)]
        [hashtable]$Questionnaire
    )

    $state = $script:DeskPilot
    $intercom = $state.Intercom
    if (-not $intercom -or -not $intercom.Running) { return }
    if (-not (Test-DpIntercomProject -Settings $state.Settings).allowed) { return }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('Reply to this message to answer.')

    $body = [System.Text.StringBuilder]::new()
    $questionNumber = 0
    foreach ($question in @($Questionnaire.questions)) {
        $questionNumber++
        if ($questionNumber -gt 1) { $null = $body.Append("`n`n") }
        $null = $body.Append([string]$question.question)
        $optionNumber = 0
        foreach ($option in @($question.options)) {
            $optionNumber++
            $null = $body.Append("`n  $optionNumber) ").Append([string]$option.label)
        }
    }

    $timeout = 60
    if ($state.Settings.intercom) { $timeout = [int]$state.Settings.intercom.questionTimeoutMinutes }
    if ($timeout -lt 1) { $timeout = 60 }
    $lines.Add("Expires in $timeout minutes.")

    $intercom.PendingQuestion = @{
        id             = $RequestId
        conversationId = $ConversationId
        messageId      = 0
        askedUtc       = [DateTime]::UtcNow
    }

    $sendParams = @{
        Title   = "The agent needs your input - $([string]$Questionnaire.title)"
        Line    = @($lines.ToArray())
        Kind    = 'question'
        Capture = 'question'
    }
    $bodyText = $body.ToString()
    if (-not [string]::IsNullOrWhiteSpace($bodyText)) { $sendParams.Body = $bodyText }

    if (-not (Send-DpIntercomMessage @sendParams)) { $intercom.PendingQuestion = $null }
}
