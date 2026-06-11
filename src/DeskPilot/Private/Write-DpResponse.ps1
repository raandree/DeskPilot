function Write-DpResponse {
    <#
    .SYNOPSIS
        Writes a complete HTTP response to a network stream.
    .DESCRIPTION
        Serialises a JSON object, text, or raw bytes into an HTTP/1.1 response
        with a Connection: close header and writes it to the stream. Use -NoBody
        or a 204 status for an empty response.
    .PARAMETER Stream
        The network stream to write to.
    .PARAMETER Status
        The HTTP status code.
    .PARAMETER Json
        An object serialised as the JSON body (default when no other body given).
    .PARAMETER Text
        A text body.
    .PARAMETER Bytes
        A raw byte body (for static assets).
    .PARAMETER ContentType
        The Content-Type header value.
    .PARAMETER NoBody
        Send no body.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.IO.Stream]$Stream,

        [int]$Status = 200,
        [object]$Json,
        [string]$Text,
        [byte[]]$Bytes,
        [string]$ContentType = 'application/json; charset=utf-8',
        [switch]$NoBody
    )

    $reason = switch ($Status) {
        200 { 'OK' } 201 { 'Created' } 202 { 'Accepted' } 204 { 'No Content' }
        400 { 'Bad Request' } 401 { 'Unauthorized' } 403 { 'Forbidden' }
        404 { 'Not Found' } 409 { 'Conflict' } 500 { 'Internal Server Error' }
        502 { 'Bad Gateway' } default { 'OK' }
    }

    [byte[]]$payload = [byte[]]::new(0)
    if (-not $NoBody -and $Status -ne 204) {
        if ($PSBoundParameters.ContainsKey('Bytes') -and $null -ne $Bytes) {
            $payload = $Bytes
        }
        elseif ($PSBoundParameters.ContainsKey('Text')) {
            $payload = [System.Text.Encoding]::UTF8.GetBytes($Text)
        }
        else {
            $json = if ($null -ne $Json) { $Json | ConvertTo-Json -Depth 12 -Compress } else { '{}' }
            $payload = [System.Text.Encoding]::UTF8.GetBytes($json)
            $ContentType = 'application/json; charset=utf-8'
        }
    }

    $head = [System.Text.StringBuilder]::new()
    [void]$head.Append("HTTP/1.1 $Status $reason`r`n")
    [void]$head.Append("Content-Type: $ContentType`r`n")
    [void]$head.Append("Content-Length: $($payload.Length)`r`n")
    [void]$head.Append("Cache-Control: no-store`r`n")
    [void]$head.Append("Connection: close`r`n`r`n")

    $headBytes = [System.Text.Encoding]::ASCII.GetBytes($head.ToString())
    $Stream.Write($headBytes, 0, $headBytes.Length)
    if ($payload.Length -gt 0) { $Stream.Write($payload, 0, $payload.Length) }
    $Stream.Flush()
}
