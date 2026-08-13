function Wait-DpResponseRetry
{
    <#
    .SYNOPSIS
        Waits before a response retry while keeping Stop responsive.
    .DESCRIPTION
        Splits the requested delay into short slices and services pending Host
        Server requests between them. Returns false as soon as a Stop request sets
        CancelRequested; otherwise returns true after the full delay.
    .PARAMETER Milliseconds
        Total delay before the next Engine attempt.
    .PARAMETER PollMilliseconds
        Maximum sleep slice between pending-request pumps. Defaults to 50 ms.
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param
    (
        [Parameter(Mandatory)]
        [ValidateRange(0, [int]::MaxValue)]
        [int]$Milliseconds,

        [Parameter()]
        [ValidateRange(1, 1000)]
        [int]$PollMilliseconds = 50
    )

    $remaining = $Milliseconds
    while ($remaining -gt 0) {
        Invoke-DpPendingRequest
        if ($script:DeskPilot.CancelRequested) { return $false }

        $slice = [Math]::Min($PollMilliseconds, $remaining)
        Start-Sleep -Milliseconds $slice
        $remaining -= $slice
    }

    Invoke-DpPendingRequest
    return -not [bool]$script:DeskPilot.CancelRequested
}
