function ConvertTo-DpQuestionnaire {
    <#
    .SYNOPSIS
        Normalizes an Engine Ask-User string into a Questionnaire payload.
    .DESCRIPTION
        Accepts the JSON-string protocol DeskPilot asks the Model to place in
        ask_user.question. Valid structured input becomes a bounded wizard with
        selectable options and optional free text. Plain or malformed input
        remains usable as one free-text question.
    .PARAMETER InputObject
        The raw ask_user.question string from the Engine Tool call.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$InputObject
    )

    $limitText = {
        param([object]$Value, [int]$MaxLength)
        $text = ([string]$Value).Trim()
        if ($text.Length -gt $MaxLength) { return $text.Substring(0, $MaxLength) }
        $text
    }
    $readValue = {
        param([object]$Value, [string]$Name, [object]$Default = $null)
        if ($null -eq $Value) { return $Default }
        if ($Value -is [System.Collections.IDictionary]) {
            if ($Value.Contains($Name)) { return $Value[$Name] }
            return $Default
        }
        $property = $Value.PSObject.Properties[$Name]
        if ($property) { return $property.Value }
        $Default
    }
    $readBoolean = {
        param([object]$Value, [bool]$Default)
        if ($Value -is [bool]) { return $Value }
        $parsed = $false
        if ([bool]::TryParse([string]$Value, [ref]$parsed)) { return $parsed }
        $Default
    }
    $newFallback = {
        $questionText = & $limitText $InputObject 2000
        @{
            structured = $false
            title      = 'Your input is needed'
            questions  = @(@{
                    header            = 'Question'
                    question          = $questionText
                    options           = @()
                    multiSelect       = $false
                    allowFreeformInput = $true
                })
        }
    }

    $jsonText = $InputObject.Trim()
    $fence = [regex]::Match($jsonText, '(?s)^```(?:json)?\s*(.*?)\s*```$')
    if ($fence.Success) { $jsonText = $fence.Groups[1].Value.Trim() }

    try {
        $parsed = $jsonText | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return & $newFallback
    }

    $rawQuestions = @(& $readValue $parsed 'questions' @())
    if ($rawQuestions.Count -eq 0) { return & $newFallback }

    $questions = [System.Collections.Generic.List[hashtable]]::new()
    $questionNumber = 0
    foreach ($rawQuestion in ($rawQuestions | Select-Object -First 10)) {
        $questionText = & $limitText (& $readValue $rawQuestion 'question' '') 1000
        if ([string]::IsNullOrWhiteSpace($questionText)) { continue }
        $questionNumber++

        $header = & $limitText (& $readValue $rawQuestion 'header' '') 80
        if ([string]::IsNullOrWhiteSpace($header)) { $header = "Question $questionNumber" }

        $options = [System.Collections.Generic.List[hashtable]]::new()
        $optionLabels = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::Ordinal
        )
        foreach ($rawOption in (@(& $readValue $rawQuestion 'options' @()) | Select-Object -First 12)) {
            if ($null -eq $rawOption) { continue }
            $label = if ($rawOption -is [string]) {
                & $limitText $rawOption 160
            }
            else {
                & $limitText (& $readValue $rawOption 'label' '') 160
            }
            if ([string]::IsNullOrWhiteSpace($label)) { continue }
            if (-not $optionLabels.Add($label)) { continue }
            $description = if ($rawOption -is [string]) {
                ''
            }
            else {
                & $limitText (& $readValue $rawOption 'description' '') 300
            }
            $options.Add(@{ label = $label; description = $description })
        }

        $allowFreeform = & $readBoolean (
            & $readValue $rawQuestion 'allowFreeformInput' ($options.Count -eq 0)
        ) ($options.Count -eq 0)
        if ($options.Count -eq 0) { $allowFreeform = $true }
        $multiSelect = $options.Count -gt 1 -and (& $readBoolean (
                & $readValue $rawQuestion 'multiSelect' $false
            ) $false)

        $questions.Add(@{
                header             = $header
                question           = $questionText
                options            = @($options.ToArray())
                multiSelect        = [bool]$multiSelect
                allowFreeformInput = [bool]$allowFreeform
            })
    }

    if ($questions.Count -eq 0) { return & $newFallback }

    $title = & $limitText (& $readValue $parsed 'title' '') 180
    if ([string]::IsNullOrWhiteSpace($title)) {
        $headers = @($questions | ForEach-Object { $_.header }) -join ', '
        $noun = if ($questions.Count -eq 1) { 'question' } else { 'questions' }
        $title = "Asking $($questions.Count) $noun ($headers)"
        $title = & $limitText $title 180
    }

    @{
        structured = $true
        title      = $title
        questions  = @($questions.ToArray())
    }
}
