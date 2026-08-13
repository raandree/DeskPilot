function Merge-DpRetriedTurnUsage
{
    <#
    .SYNOPSIS
        Merges Engine Usage from every attempt of a successful retried Turn.
    .DESCRIPTION
        Uses the exact delta between pre- and post-Turn Engine Usage summaries so
        an empty but billable attempt is not hidden behind the final successful
        result. Unknown fields from the final result are preserved. When either
        summary is unavailable, the final result is returned unchanged.
    .PARAMETER Usage
        Usage mapped from the final successful Engine result.
    .PARAMETER Before
        Engine Usage summary captured before the first attempt.
    .PARAMETER After
        Engine Usage summary captured after the successful attempt.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param
    (
        [Parameter(Mandatory)]
        [hashtable]$Usage,

        [AllowNull()]
        [object]$Before,

        [AllowNull()]
        [object]$After
    )

    $merged = @{}
    foreach ($key in $Usage.Keys) { $merged[$key] = $Usage[$key] }
    if ($null -eq $Before -or $null -eq $After) { return $merged }

    $calls = [Math]::Max(
        0,
        [int](Get-DpPropertyValue -InputObject $After -Name @('Calls') -Default 0) -
        [int](Get-DpPropertyValue -InputObject $Before -Name @('Calls') -Default 0)
    )
    if ($calls -lt 1) { return $merged }

    $promptTokens = [Math]::Max(
        0,
        [int](Get-DpPropertyValue -InputObject $After -Name @('PromptTokens') -Default 0) -
        [int](Get-DpPropertyValue -InputObject $Before -Name @('PromptTokens') -Default 0)
    )
    $completionTokens = [Math]::Max(
        0,
        [int](Get-DpPropertyValue -InputObject $After -Name @('CompletionTokens') -Default 0) -
        [int](Get-DpPropertyValue -InputObject $Before -Name @('CompletionTokens') -Default 0)
    )
    $totalTokens = [Math]::Max(
        0,
        [int](Get-DpPropertyValue -InputObject $After -Name @('TotalTokens') -Default 0) -
        [int](Get-DpPropertyValue -InputObject $Before -Name @('TotalTokens') -Default 0)
    )
    $beforeCost = Get-DpPropertyValue -InputObject $Before -Name @('CostUSD') -Default $null
    $afterCost = Get-DpPropertyValue -InputObject $After -Name @('CostUSD') -Default $null
    $beforeCredits = Get-DpPropertyValue -InputObject $Before -Name @('Credits') -Default $null
    $afterCredits = Get-DpPropertyValue -InputObject $After -Name @('Credits') -Default $null

    $merged.promptTokens = [Math]::Max([int]$merged.promptTokens, $promptTokens)
    $merged.completionTokens = [Math]::Max([int]$merged.completionTokens, $completionTokens)
    $merged.totalTokens = [Math]::Max(
        [int]$merged.totalTokens,
        $(if ($totalTokens -gt 0) { $totalTokens } else { $promptTokens + $completionTokens })
    )
    if ($null -ne $beforeCost -and $null -ne $afterCost) {
        $merged.costUSD = [Math]::Round([Math]::Max([double]$merged.costUSD, [double]$afterCost - [double]$beforeCost), 6)
    }
    if ($null -ne $beforeCredits -and $null -ne $afterCredits) {
        $merged.credits = [Math]::Round([Math]::Max([double]$merged.credits, [double]$afterCredits - [double]$beforeCredits), 4)
    }
    # The summary exposes Engine call count, not each failed call's internal
    # iteration count. Every pre-stream retry adds at least one round-trip; keep
    # the final result's exact iterations and add that conservative minimum.
    $merged.iterations = [int]$merged.iterations + [Math]::Max(0, $calls - 1)

    $merged
}
