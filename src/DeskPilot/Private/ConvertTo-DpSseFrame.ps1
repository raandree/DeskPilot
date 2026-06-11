function ConvertTo-DpSseFrame {
    <#
    .SYNOPSIS
        Builds a Server-Sent Events frame for a named event.
    .DESCRIPTION
        Serialises Data to single-line JSON (or uses it verbatim when already a
        string) and returns a complete SSE frame: an 'event:' line, a 'data:'
        line, and the terminating blank line. Newlines in the payload are
        flattened so the frame stays valid.
    .PARAMETER EventName
        The SSE event name (for example 'delta', 'done', 'error').
    .PARAMETER Data
        The payload object or string.
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$EventName,

        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Data
    )

    $json = if ($Data -is [string]) { $Data } else { $Data | ConvertTo-Json -Compress -Depth 12 }
    if ($null -eq $json) { $json = '' }
    $json = $json -replace "`r", '' -replace "`n", ' '
    "event: $EventName`ndata: $json`n`n"
}
