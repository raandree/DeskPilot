function ConvertTo-DpQuestionnaireAnswer {
    <#
    .SYNOPSIS
        Serializes collected Questionnaire answers into the string the bridge takes.
    .DESCRIPTION
        Intercom collects a multi-question Questionnaire one question at a time,
        but the Ask-User bridge takes a single answer string for the whole thing -
        the same one the browser wizard submits after its last step. This produces
        exactly that string, so a Turn cannot tell whether it was answered at the
        machine or from a phone.

        The shape is the browser's `serializeQuestionnaireAnswer` and must not
        drift from it: an unstructured Questionnaire answers with plain text, and
        a structured one with `{"answers":[{header,selectedOptions,freeText}]}`.
    .PARAMETER Question
        The normalized questions, in order, each carrying the collected
        `selectedOptions` and `freeText`.
    .PARAMETER Structured
        Whether the Questionnaire came from the structured JSON contract. An
        unstructured one is a single free-text question and answers as bare text.
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Question,

        [bool]$Structured = $true
    )

    $questions = @($Question)
    if ($questions.Count -eq 0) { return '' }

    if (-not $Structured) {
        $first = $questions[0]
        $text = ([string](Get-DpPropertyValue -InputObject $first -Name @('freeText') -Default '')).Trim()
        if ($text) { return $text }
        $selected = @(Get-DpPropertyValue -InputObject $first -Name @('selectedOptions') -Default @())
        if ($selected.Count -gt 0) { return [string]$selected[0] }
        return ''
    }

    $answers = @(foreach ($item in $questions) {
            [ordered]@{
                header          = [string](Get-DpPropertyValue -InputObject $item -Name @('header') -Default '')
                # Cast every time: ConvertTo-Json emits a scalar for a one-element
                # collection that has lost its array-ness, and the browser contract
                # is a list.
                selectedOptions = [array]@(Get-DpPropertyValue -InputObject $item -Name @('selectedOptions') -Default @())
                freeText        = ([string](Get-DpPropertyValue -InputObject $item -Name @('freeText') -Default '')).Trim()
            }
        })

    @{ answers = [array]$answers } | ConvertTo-Json -Depth 6 -Compress
}
