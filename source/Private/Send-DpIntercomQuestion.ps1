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

    $questions = @($Questionnaire.questions)

    # Buttons are offered only for a single question with options, where one tap is
    # unambiguous. A multi-question or multi-select Questionnaire needs a written
    # answer, and a keyboard that could not express it would be a trap rather than
    # a shortcut - so those keep the reply flow and say so.
    $choices = @()
    $token = ''
    $options = @()
    if ($questions.Count -eq 1 -and @($questions[0].options).Count -gt 0 -and -not [bool]$questions[0].multiSelect) {
        $options = @(@($questions[0].options) | ForEach-Object { [string]$_.label })
        $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
        $index = -1
        $choices = @($options | ForEach-Object { $index++; @{ label = $_; data = "q|$token|$index" } })
    }
    $keyboard = if ($choices.Count -gt 0) { Get-DpIntercomKeyboard -Choice $choices } else { $null }
    # The nonce is only meaningful if the buttons carrying it actually shipped.
    if (-not $keyboard) { $token = ''; $options = @() }

    # Why a question arrived as a numbered list rather than buttons is otherwise
    # invisible from the phone, and every cause looks identical there.
    if (-not $keyboard) {
        $why = if ($questions.Count -ne 1) { "$($questions.Count) questions" }
        elseif (@($questions[0].options).Count -eq 0) { 'no options' }
        elseif ([bool]$questions[0].multiSelect) { 'multi-select' }
        else { 'the keyboard could not be built' }
        Add-DpIntercomLog -Direction 'out' -Kind 'question-no-keyboard' -Detail "Sent as a numbered list: $why."
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add($(if ($keyboard) { 'Tap an answer below, or reply to this message with your own.' } else { 'Reply to this message to answer.' }))

    $body = [System.Text.StringBuilder]::new()
    $questionNumber = 0
    foreach ($question in $questions) {
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
        token          = $token
        options        = @($options)
    }

    $sendParams = @{
        Title   = "The agent needs your input - $([string]$Questionnaire.title)"
        Line    = @($lines.ToArray())
        Kind    = 'question'
        Capture = 'question'
    }
    if ($keyboard) { $sendParams.Keyboard = $keyboard }
    $bodyText = $body.ToString()
    if (-not [string]::IsNullOrWhiteSpace($bodyText)) { $sendParams.Body = $bodyText }

    if (-not (Send-DpIntercomMessage @sendParams)) { $intercom.PendingQuestion = $null }
}
