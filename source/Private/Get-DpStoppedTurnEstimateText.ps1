function Get-DpStoppedTurnEstimateText {
    <#
    .SYNOPSIS
        Builds the visible input text used to estimate an interrupted Turn.
    .DESCRIPTION
        Combines the optional system prompt, replayed Conversation history, and
        current prompt without assuming optional hashtable keys or object
        properties exist under StrictMode.
    .PARAMETER TurnParameter
        The Invoke-Shp parameter hashtable assembled for the Turn.
    .PARAMETER History
        Replayed Conversation history entries.
    .PARAMETER Prompt
        The current user prompt.
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$TurnParameter,

        [AllowEmptyCollection()]
        [object[]]$History = @(),

        [Parameter(Mandatory)]
        [string]$Prompt
    )

    $parts = [System.Collections.Generic.List[string]]::new()
    if ($TurnParameter.ContainsKey('SystemPrompt')) {
        $systemPrompt = [string]$TurnParameter.SystemPrompt
        if (-not [string]::IsNullOrWhiteSpace($systemPrompt)) {
            $parts.Add($systemPrompt)
        }
    }

    foreach ($entry in @($History)) {
        if ($null -eq $entry) { continue }
        $content = if ($entry -is [System.Collections.IDictionary]) {
            $entry['content']
        }
        else {
            $property = $entry.PSObject.Properties['content']
            if ($property) { $property.Value } else { $null }
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$content)) {
            $parts.Add([string]$content)
        }
    }

    $parts.Add($Prompt)
    $parts -join "`n`n"
}
