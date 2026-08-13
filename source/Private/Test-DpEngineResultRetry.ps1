function Test-DpEngineResultRetry
{
    <#
    .SYNOPSIS
        Tests whether an Engine result is safe and useful to retry.
    .DESCRIPTION
        Returns true only for an empty Engine result produced before any response
        or Tool Activity streamed. Once a frame has streamed, restarting the Turn
        could repeat a command or write, so an empty final answer stays on the
        ordinary completed-Turn path.
    .PARAMETER Result
        The object returned by Invoke-Shp, or null when the pipeline returned none.
    .PARAMETER EmittedCount
        Number of response or Tool Activity frames emitted during this Turn.
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param
    (
        [Parameter()]
        [AllowNull()]
        [object]$Result,

        [Parameter(Mandatory)]
        [ValidateRange(0, [int]::MaxValue)]
        [int]$EmittedCount
    )

    return $EmittedCount -eq 0 -and (Test-DpEmptyEngineResult -Result $Result)
}
