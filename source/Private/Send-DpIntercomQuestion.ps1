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
    if ($questions.Count -eq 0) { return }

    # Copied rather than annotated in place, so the collected answers never leak
    # back into the Questionnaire the browser is rendering from the same request.
    $steps = @(foreach ($question in $questions) {
            @{
                header             = [string]$question.header
                question           = [string]$question.question
                options            = @($question.options)
                multiSelect        = [bool]$question.multiSelect
                allowFreeformInput = [bool]$question.allowFreeformInput
                selectedOptions    = @()
                freeText           = ''
            }
        })

    $intercom.PendingQuestion = @{
        id             = $RequestId
        conversationId = $ConversationId
        messageId      = 0
        # Telegram message ids are per-chat sequences, so an answer is only an
        # answer when it replies to this message in the chat it was sent to.
        chatId         = $(
            $asked = [string](Get-DpPropertyValue -InputObject $intercom -Name @('ReplyChatId') -Default '')
            if ($asked) { $asked } else { [string]$state.Settings.intercom.chatId }
        )
        askedUtc       = [DateTime]::UtcNow
        title          = [string]$Questionnaire.title
        # Absent means unstructured, exactly as the browser's `structured === true`
        # reads it - and that decides whether the answer is JSON or bare text.
        structured     = [bool](Get-DpPropertyValue -InputObject $Questionnaire -Name @('structured') -Default $false)
        questions      = $steps
        step           = 0
        # Set per step by Send-DpIntercomQuestionStep; the nonce, the labels its
        # indices resolve against, and whether taps accumulate.
        token          = ''
        options        = @()
        multiSelect    = $false
    }

    if (-not (Send-DpIntercomQuestionStep)) { $intercom.PendingQuestion = $null }
}
