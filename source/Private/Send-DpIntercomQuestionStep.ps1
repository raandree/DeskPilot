function Send-DpIntercomQuestionStep {
    <#
    .SYNOPSIS
        Sends the one question a pending Questionnaire is currently on.
    .DESCRIPTION
        The phone asks a Questionnaire one question at a time, because that is the
        only shape a tap can answer. DeskPilot's own Tool description tells the
        model to bundle every question into one call, so a real Questionnaire
        arrives with several at once and a single message could never carry a
        keyboard that expressed the answer.

        Each step mints a fresh nonce and becomes the new answer target: Telegram
        leaves old buttons on screen forever, so a tap must prove it belongs to the
        question currently waiting rather than to one already answered.
    .OUTPUTS
        System.Boolean - whether the step was queued.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Advances in-process Intercom state from an already-authorised question; ShouldProcess is not meaningful on the accept thread.')]
    param()

    $state = $script:DeskPilot
    $intercom = $state.Intercom
    $pending = $intercom.PendingQuestion
    if (-not $pending) { return $false }

    $questions = @($pending.questions)
    $step = [int]$pending.step
    if ($step -lt 0 -or $step -ge $questions.Count) { return $false }

    $question = $questions[$step]
    $optionLabels = @(@($question.options) | ForEach-Object { [string]$_.label })
    $multiSelect = [bool]$question.multiSelect
    $allowFreeform = [bool]$question.allowFreeformInput
    $selected = @($question.selectedOptions)

    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $choices = @()
    if ($optionLabels.Count -gt 0) {
        $index = -1
        $choices = @($optionLabels | ForEach-Object {
                $index++
                # A tick on the label is the only feedback a toggled option gets:
                # editing the message per tap would cost a Telegram call each time.
                $label = $(if ($multiSelect -and $selected -contains $_) { "* $_" } else { $_ })
                @{ label = $label; data = "q|$token|$index" }
            })
        if ($multiSelect) { $choices += @{ label = 'Done'; data = "q|$token|d" } }
    }

    $keyboard = if ($choices.Count -gt 0) { Get-DpIntercomKeyboard -Choice $choices } else { $null }
    if (-not $keyboard) { $token = ''; $optionLabels = @() }

    $pending.token = $token
    $pending.options = @($optionLabels)
    $pending.multiSelect = $multiSelect
    # Each step is its own message, so the reply nonce moves with it.
    $pending.messageId = 0

    $lines = [System.Collections.Generic.List[string]]::new()
    if ($questions.Count -gt 1) { $lines.Add("Question $($step + 1) of $($questions.Count) - $([string]$question.header)") }
    if ($keyboard -and $multiSelect) {
        $lines.Add('Tap every answer that applies, then tap Done.')
    }
    elseif ($keyboard) {
        $lines.Add($(if ($allowFreeform) { 'Tap an answer below, or reply to this message with your own.' } else { 'Tap an answer below.' }))
    }
    else {
        $lines.Add('Reply to this message to answer.')
    }

    if (-not $keyboard -and $optionLabels.Count -eq 0 -and @($question.options).Count -gt 0) {
        # The keyboard was dropped whole rather than shipping a button that fails
        # when tapped, so say why the numbers came back instead.
        Add-DpIntercomLog -Direction 'out' -Kind 'question-no-keyboard' -Detail 'Sent as a numbered list: the keyboard could not be built.'
    }

    $body = [System.Text.StringBuilder]::new()
    $null = $body.Append([string]$question.question)
    if (-not $keyboard) {
        $optionNumber = 0
        foreach ($option in @($question.options)) {
            $optionNumber++
            $null = $body.Append("`n  $optionNumber) ").Append([string]$option.label)
        }
    }

    $timeout = 60
    if ($state.Settings.intercom) { $timeout = [int]$state.Settings.intercom.questionTimeoutMinutes }
    if ($timeout -lt 1) { $timeout = 60 }
    if ($step -eq 0) { $lines.Add("Expires in $timeout minutes.") }

    $sendParams = @{
        Title   = "The agent needs your input - $([string]$pending.title)"
        Line    = @($lines.ToArray())
        Kind    = 'question'
        Capture = 'question'
        Body    = $body.ToString()
    }
    if ($keyboard) { $sendParams.Keyboard = $keyboard }

    Send-DpIntercomMessage @sendParams
}
