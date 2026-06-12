function ConvertTo-DpIsoString {
    <#
    .SYNOPSIS
        Normalises a value to a round-trippable ISO-8601 UTC string.
    .DESCRIPTION
        ConvertFrom-Json auto-converts ISO-8601 date strings into [DateTime]
        objects, so reading a persisted timestamp back and casting it with
        [string] would reformat it in the current culture. This helper coerces a
        DateTime (or DateTimeOffset, or an existing string) back to an ISO-8601
        UTC string ('o' format), preserving timestamps across a load/save cycle.
    .PARAMETER Value
        The value to normalise (a string, DateTime, DateTimeOffset, or $null).
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString('o') }
    if ($Value -is [datetimeoffset]) { return $Value.UtcDateTime.ToString('o') }
    [string]$Value
}
