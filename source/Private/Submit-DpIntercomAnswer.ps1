function Submit-DpIntercomAnswer {
    <#
    .SYNOPSIS
        Records a typed reply against the question the Questionnaire is on.
    .DESCRIPTION
        The written half of answering; the tapped half is Invoke-DpIntercomCallback.
        Both end in Move-DpIntercomInterview, so the acknowledgement, the "that
        question has gone" wording and the release of the waiting pipeline cannot
        drift apart between the two routes.

        Typed text is mapped onto the question's options first - by the number the
        message printed, or by an exact label - because a numbered list is what the
        operator sees when a keyboard could not be built, and because typing "2" is
        an old habit worth honouring. Only a question that permits free text keeps
        the words as written; one that does not is refused rather than answered
        with something the browser wizard would have refused to submit.
    .PARAMETER Answer
        The reply text.
    .OUTPUTS
        System.Boolean - whether the whole Questionnaire was completed and accepted.
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

    if (-not $pending) {
        $null = Send-DpIntercomMessage -Title 'That question is no longer waiting for an answer.' -Line @(
            'Send a new instruction instead, or /status to see what is happening.'
        ) -Kind 'notice'
        return $false
    }

    $questions = @($pending.questions)
    $step = [int]$pending.step
    if ($step -lt 0 -or $step -ge $questions.Count) {
        $intercom.PendingQuestion = $null
        return $false
    }
    $question = $questions[$step]

    $labels = @(@($question.options) | ForEach-Object { [string]$_.label })
    $text = ([string]$Answer).Trim()

    # After 'Something else' the words are the answer, so mapping them onto the
    # options would turn a literal "2" into the second choice.
    $verbatim = [bool](Get-DpPropertyValue -InputObject $pending -Name @('awaitingFreeText') -Default $false)

    $picked = [System.Collections.Generic.List[string]]::new()
    if ($labels.Count -gt 0 -and -not $verbatim) {
        foreach ($piece in @($text -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
            $number = 0
            if ([int]::TryParse($piece, [ref]$number) -and $number -ge 1 -and $number -le $labels.Count) {
                if (-not $picked.Contains($labels[$number - 1])) { $picked.Add($labels[$number - 1]) }
                continue
            }
            $match = @($labels | Where-Object { $_ -eq $piece })
            if ($match.Count -ge 1 -and -not $picked.Contains([string]$match[0])) { $picked.Add([string]$match[0]) }
        }
        # One answer means one answer, however many numbers were typed.
        if (-not [bool]$question.multiSelect -and $picked.Count -gt 1) {
            $only = $picked[0]
            $picked.Clear()
            $picked.Add($only)
        }
    }

    if ($picked.Count -gt 0) {
        $question.selectedOptions = @($picked.ToArray())
        $question.freeText = ''
    }
    elseif ($text -and ($verbatim -or [bool]$question.allowFreeformInput)) {
        # A multi-select keeps what was already ticked: "these two, plus this".
        # A single-choice question is either/or, as it is in the browser.
        if (-not [bool]$question.multiSelect) { $question.selectedOptions = @() }
        $question.freeText = $text
    }
    else {
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add('That did not match any of the choices for this question.')
        $lines.Add('Tap one of the buttons, reply with its number, or tap "Something else - type it".')
        $number = 0
        foreach ($label in $labels) { $number++; $lines.Add("  $number) $label") }
        $null = Send-DpIntercomMessage -Title 'I need one of the choices.' -Line @($lines.ToArray()) -Kind 'notice'
        return $false
    }

    Move-DpIntercomInterview
}
