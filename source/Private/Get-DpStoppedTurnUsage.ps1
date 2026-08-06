function Get-DpStoppedTurnUsage {
    <#
    .SYNOPSIS
        Maps exact or estimated Usage for an interrupted Turn.
    .DESCRIPTION
        Prefers the nonnegative delta between Engine Usage summaries when the
        cancelled call reached the Engine log. When hard cancellation prevented
        that log entry, falls back to ShellPilot's preflight input estimate and
        marks the result as estimated and input-only.
    .PARAMETER Before
        Engine Usage summary captured before the Turn.
    .PARAMETER After
        Engine Usage summary captured after cancellation.
    .PARAMETER Estimate
        ShellPilot Get-ShpCostEstimate output for the assembled visible context.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]
        [object]$Before,

        [AllowNull()]
        [object]$After,

        [AllowNull()]
        [object]$Estimate
    )

    $getValue = {
        param([object]$InputObject, [string]$Name, [object]$Default)
        if ($null -eq $InputObject) { return $Default }
        if ($InputObject -is [System.Collections.IDictionary]) {
            if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
            return $Default
        }
        $property = $InputObject.PSObject.Properties[$Name]
        if ($property) { return $property.Value }
        $Default
    }

    $hasExactBaseline = $null -ne $Before -and $null -ne $After
    $calls = if ($hasExactBaseline) {
        [Math]::Max(0, [int](& $getValue $After 'Calls' 0) - [int](& $getValue $Before 'Calls' 0))
    }
    else {
        0
    }
    if ($hasExactBaseline -and $calls -gt 0) {
        $promptTokens = [Math]::Max(
            0,
            [int](& $getValue $After 'PromptTokens' 0) - [int](& $getValue $Before 'PromptTokens' 0)
        )
        $completionTokens = [Math]::Max(
            0,
            [int](& $getValue $After 'CompletionTokens' 0) - [int](& $getValue $Before 'CompletionTokens' 0)
        )
        $totalTokens = [Math]::Max(
            0,
            [int](& $getValue $After 'TotalTokens' 0) - [int](& $getValue $Before 'TotalTokens' 0)
        )
        return @{
            promptTokens     = $promptTokens
            completionTokens = $completionTokens
            totalTokens      = if ($totalTokens -gt 0) { $totalTokens } else { $promptTokens + $completionTokens }
            costUSD          = [Math]::Round(
                [Math]::Max([double]0, [double](& $getValue $After 'CostUSD' 0) - [double](& $getValue $Before 'CostUSD' 0)),
                6
            )
            credits          = [Math]::Round(
                [Math]::Max([double]0, [double](& $getValue $After 'Credits' 0) - [double](& $getValue $Before 'Credits' 0)),
                4
            )
            iterations       = $calls
            priced           = $null -ne (& $getValue $After 'CostUSD' $null)
            estimated        = $false
            estimateScope    = $null
            partial          = $true
        }
    }

    $estimatedTokens = [Math]::Max(0, [int](& $getValue $Estimate 'EstimatedInputTokens' 0))
    @{
        promptTokens     = $estimatedTokens
        completionTokens = 0
        totalTokens      = $estimatedTokens
        costUSD          = [Math]::Round(
            [Math]::Max([double]0, [double](& $getValue $Estimate 'EstimatedInputCostUSD' 0)),
            6
        )
        credits          = [Math]::Round(
            [Math]::Max([double]0, [double](& $getValue $Estimate 'EstimatedInputCredits' 0)),
            4
        )
        iterations       = 1
        priced           = $null -ne (& $getValue $Estimate 'EstimatedInputCostUSD' $null)
        estimated        = $true
        estimateScope    = 'input-only'
        partial          = $true
    }
}
