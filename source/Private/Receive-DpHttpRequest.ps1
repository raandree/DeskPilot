function Receive-DpHttpRequest {
    <#
    .SYNOPSIS
        Reads and parses one HTTP/1.1 request from a network stream.
    .DESCRIPTION
        Reads the request line and headers up to the blank-line terminator, then
        reads the body when a Content-Length is present. Returns a hashtable with
        Method, Path, Query, Headers and Body, or $null when the connection
        closed before a request arrived.
    .PARAMETER Stream
        The connected network stream to read from.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [System.IO.Stream]$Stream
    )

    $headerBytes = [System.Collections.Generic.List[byte]]::new()
    $one = [byte[]]::new(1)
    $maxHeader = 65536
    while ($true) {
        $read = $Stream.Read($one, 0, 1)
        if ($read -le 0) { break }
        $headerBytes.Add($one[0])
        $count = $headerBytes.Count
        if ($count -ge 4 -and
            $headerBytes[$count - 4] -eq 13 -and $headerBytes[$count - 3] -eq 10 -and
            $headerBytes[$count - 2] -eq 13 -and $headerBytes[$count - 1] -eq 10) {
            break
        }
        if ($count -gt $maxHeader) { throw 'Request header too large.' }
    }
    if ($headerBytes.Count -eq 0) { return $null }

    $headerText = [System.Text.Encoding]::ASCII.GetString($headerBytes.ToArray())
    $lines = $headerText -split "`r`n"
    $requestLine = $lines[0]
    $segments = $requestLine -split ' '
    if ($segments.Count -lt 2) { return $null }
    $method = $segments[0]
    $rawUrl = $segments[1]

    $headers = @{}
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $idx = $line.IndexOf(':')
        if ($idx -lt 1) { continue }
        $headers[$line.Substring(0, $idx).Trim()] = $line.Substring($idx + 1).Trim()
    }

    $path = $rawUrl
    $query = @{}
    $qIndex = $rawUrl.IndexOf('?')
    if ($qIndex -ge 0) {
        $path = $rawUrl.Substring(0, $qIndex)
        $queryString = $rawUrl.Substring($qIndex + 1)
        foreach ($pair in ($queryString -split '&')) {
            if (-not $pair) { continue }
            $kv = $pair -split '=', 2
            $name = [uri]::UnescapeDataString($kv[0])
            $query[$name] = if ($kv.Count -gt 1) { [uri]::UnescapeDataString($kv[1]) } else { '' }
        }
    }
    $path = [uri]::UnescapeDataString($path)

    $body = $null
    $bodyBytes = $null
    $contentLength = 0
    if ($headers['Content-Length'] -and [int]::TryParse($headers['Content-Length'], [ref]$contentLength) -and $contentLength -gt 0) {
        $bodyBuffer = [byte[]]::new($contentLength)
        $offset = 0
        while ($offset -lt $contentLength) {
            $chunk = $Stream.Read($bodyBuffer, $offset, $contentLength - $offset)
            if ($chunk -le 0) { break }
            $offset += $chunk
        }
        if ($offset -lt $contentLength) {
            $bodyBytes = $bodyBuffer[0..($offset - 1)]
        }
        else {
            $bodyBytes = $bodyBuffer
        }
        $body = [System.Text.Encoding]::UTF8.GetString($bodyBytes)
    }

    @{
        Method    = $method.ToUpperInvariant()
        Path      = $path
        Query     = $query
        Headers   = $headers
        Body      = $body
        BodyBytes = $bodyBytes
        RawUrl    = $rawUrl
    }
}
