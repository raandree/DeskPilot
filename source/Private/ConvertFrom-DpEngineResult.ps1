function ConvertFrom-DpEngineResult {
    <#
    .SYNOPSIS
        Maps an Engine (Invoke-Shp) result object to the DeskPilot Message shape.
    .DESCRIPTION
        Defensively reads the result's content, reasoning, Tool Activity and Usage
        into the API Message structure used by the SPA. Property access tolerates
        differences in the Engine result shape.
    .PARAMETER Result
        The object returned by Invoke-Shp.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Result
    )

    if ($null -eq $Result) {
        return @{
            content   = ''
            reasoning = $null
            activity  = @{ filesRead = @(); filesWritten = @(); commandsRun = @(); pagesFetched = @(); questionsAsked = @(); toolCalls = @() }
            usage     = @{ promptTokens = 0; completionTokens = 0; totalTokens = 0; costUSD = 0.0; credits = 0.0; iterations = 0 }
            tasks     = @()
        }
    }

    $content = [string](Get-DpPropertyValue -InputObject $Result -Name @('Content', 'Text', 'Answer') -Default '')
    $reasoning = [string](Get-DpPropertyValue -InputObject $Result -Name @('Reasoning') -Default '')
    if ([string]::IsNullOrWhiteSpace($reasoning)) { $reasoning = $null }

    $toolCalls = @()
    foreach ($toolCall in @(Get-DpPropertyValue -InputObject $Result -Name @('ToolCalls') -Default @())) {
        if ($null -eq $toolCall) { continue }
        $name = [string](Get-DpPropertyValue -InputObject $toolCall -Name @('Name', 'name', 'Function', 'function') -Default '')
        $arguments = Get-DpPropertyValue -InputObject $toolCall -Name @('Arguments', 'arguments', 'Args', 'args') -Default ''
        $toolCalls += @{ name = $name; arguments = "$arguments" }
    }

    $filesRead = @(Get-DpPropertyValue -InputObject $Result -Name @('FilesRead') -Default @() | ForEach-Object { [string]$_ })
    $filesWritten = @(Get-DpPropertyValue -InputObject $Result -Name @('FilesWritten') -Default @() | ForEach-Object { [string]$_ })
    $commandsRun = @(Get-DpPropertyValue -InputObject $Result -Name @('CommandsRun') -Default @() | ForEach-Object { [string]$_ })
    $questionsAsked = @(
        foreach ($rawQuestion in @(Get-DpPropertyValue -InputObject $Result -Name @('QuestionsAsked') -Default @())) {
            $questionText = [string]$rawQuestion
            if ([string]::IsNullOrWhiteSpace($questionText)) { continue }
            $questionnaire = ConvertTo-DpQuestionnaire -InputObject $questionText
            if ($questionnaire.structured) { [string]$questionnaire.title }
            else { $questionText }
        }
    )
    foreach ($toolCall in @($toolCalls | Where-Object name -eq 'ask_questions')) {
        try {
            $toolArguments = ([string]$toolCall.arguments) | ConvertFrom-Json -ErrorAction Stop
            $questionnaireJson = [string](Get-DpPropertyValue -InputObject $toolArguments -Name @('Questionnaire') -Default '')
            if ([string]::IsNullOrWhiteSpace($questionnaireJson)) { continue }
            $questionnaire = ConvertTo-DpQuestionnaire -InputObject $questionnaireJson
            if ($questionnaire.structured -and $questionsAsked -notcontains $questionnaire.title) {
                $questionsAsked += [string]$questionnaire.title
            }
        }
        catch {
            $null = $_
        }
    }
    $pagesFetched = @(Get-DpPropertyValue -InputObject $Result -Name @('PagesFetched', 'UrlsFetched') -Default @() | ForEach-Object { [string]$_ })
    if ($pagesFetched.Count -eq 0 -and $toolCalls.Count -gt 0) {
        $pagesFetched = @($toolCalls | Where-Object { $_.name -match 'fetch|url|browse' } | ForEach-Object { $_.arguments })
    }

    $usageObj = Get-DpPropertyValue -InputObject $Result -Name @('Usage') -Default $null
    $promptTokens = [int](Get-DpPropertyValue -InputObject $usageObj -Name @('PromptTokens', 'prompt_tokens', 'Prompt', 'InputTokens') -Default 0)
    $completionTokens = [int](Get-DpPropertyValue -InputObject $usageObj -Name @('CompletionTokens', 'completion_tokens', 'Completion', 'OutputTokens') -Default 0)
    $totalTokens = [int](Get-DpPropertyValue -InputObject $usageObj -Name @('TotalTokens', 'total_tokens', 'Total') -Default 0)
    if ($totalTokens -eq 0) { $totalTokens = $promptTokens + $completionTokens }

    # The Engine's promptTokens is the SUM of input tokens across every tool-calling
    # round-trip the Turn made (billed per call). Iterations is that round-trip
    # count; surfacing it lets the UI recover a single prompt's size (promptTokens /
    # iterations), which is what actually occupies the Model context window. Default
    # 1 (a Turn always makes at least one round-trip) so the divisor is never zero.
    $iterations = [int](Get-DpPropertyValue -InputObject $Result -Name @('Iterations', 'iterations', 'IterationCount') -Default 1)
    if ($iterations -lt 1) { $iterations = 1 }

    $cost = [double](Get-DpPropertyValue -InputObject $Result -Name @('CostUSD', 'Cost') -Default 0.0)
    $credits = [double](Get-DpPropertyValue -InputObject $Result -Name @('Credits', 'Credit') -Default 0.0)

    # The in-Turn Task List. The Engine returns its authoritative final, normalised
    # list on result.TodoList (a third-party boundary name); re-normalise it through
    # the DeskPilot boundary so downstream code sees one canonical Task shape.
    $tasks = ConvertTo-DpTaskList -InputObject (Get-DpPropertyValue -InputObject $Result -Name @('TodoList') -Default @())

    @{
        content   = $content
        reasoning = $reasoning
        activity  = @{
            filesRead      = @($filesRead)
            filesWritten   = @($filesWritten)
            commandsRun    = @($commandsRun)
            pagesFetched   = @($pagesFetched)
            questionsAsked = @($questionsAsked)
            toolCalls      = @($toolCalls)
        }
        usage     = @{
            promptTokens     = $promptTokens
            completionTokens = $completionTokens
            totalTokens      = $totalTokens
            costUSD          = $cost
            credits          = $credits
            iterations       = $iterations
        }
        tasks     = $tasks
    }
}
