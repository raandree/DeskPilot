function Test-DpEmptyEngineResult
{
    <#
    .SYNOPSIS
        Tests whether an Engine invocation returned usable response content.
    .DESCRIPTION
        Returns true when Invoke-Shp produced no result or a result whose Content
        is empty. Invoke-DpTurn uses this only before anything has streamed, where
        repeating the Engine call cannot duplicate answer text or Tool Activity.
    .PARAMETER Result
        The object returned by Invoke-Shp, or null when the pipeline returned none.
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param
    (
        [Parameter()]
        [AllowNull()]
        [object]$Result
    )

    if ($null -eq $Result) { return $true }

    $content = [string](Get-DpPropertyValue -InputObject $Result -Name @('Content', 'Text', 'Answer') -Default '')
    return [string]::IsNullOrWhiteSpace($content)
}
