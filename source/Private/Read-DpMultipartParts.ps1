function Read-DpMultipartParts {
    <#
    .SYNOPSIS
        Parses a multipart/form-data body into per-part records.
    .DESCRIPTION
        Splits the raw body bytes by the boundary and returns each part as a
        hashtable with Headers (lower-cased keys), Name and FileName parsed from
        Content-Disposition, ContentType, and Content (byte array). Pure
        PowerShell, byte-safe (no encoding round-trip on the payload).
    .PARAMETER Bytes
        The raw request body bytes.
    .PARAMETER Boundary
        The boundary token (without the leading dashes).
    .OUTPUTS
        System.Collections.Hashtable[]
    #>
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param(
        [Parameter(Mandatory)]
        [byte[]]$Bytes,

        [Parameter(Mandatory)]
        [string]$Boundary
    )

    $delim = [System.Text.Encoding]::ASCII.GetBytes("--$Boundary")

    # Find every boundary offset.
    $offsets = [System.Collections.Generic.List[int]]::new()
    for ($i = 0; $i -le $Bytes.Length - $delim.Length; $i++) {
        $match = $true
        for ($j = 0; $j -lt $delim.Length; $j++) {
            if ($Bytes[$i + $j] -ne $delim[$j]) { $match = $false; break }
        }
        if ($match) { $offsets.Add($i); $i += $delim.Length - 1 }
    }
    if ($offsets.Count -lt 2) { return @() }

    $parts = [System.Collections.Generic.List[hashtable]]::new()
    for ($k = 0; $k -lt $offsets.Count - 1; $k++) {
        $partStart = $offsets[$k] + $delim.Length
        # Skip an optional trailing "--" (final boundary marker).
        if ($Bytes.Length -ge $partStart + 2 -and $Bytes[$partStart] -eq 45 -and $Bytes[$partStart + 1] -eq 45) { continue }
        # Skip the CRLF after the boundary.
        if ($Bytes.Length -ge $partStart + 2 -and $Bytes[$partStart] -eq 13 -and $Bytes[$partStart + 1] -eq 10) { $partStart += 2 }

        $partEnd = $offsets[$k + 1]
        # The CRLF immediately before the next boundary belongs to the boundary delimiter, not the content.
        if ($partEnd -ge 2 -and $Bytes[$partEnd - 2] -eq 13 -and $Bytes[$partEnd - 1] -eq 10) { $partEnd -= 2 }

        # Locate the header/body split (CRLF CRLF) inside this part.
        $headerEnd = -1
        for ($i = $partStart; $i -le $partEnd - 4; $i++) {
            if ($Bytes[$i] -eq 13 -and $Bytes[$i + 1] -eq 10 -and $Bytes[$i + 2] -eq 13 -and $Bytes[$i + 3] -eq 10) { $headerEnd = $i; break }
        }
        if ($headerEnd -lt 0) { continue }

        $headerText = [System.Text.Encoding]::ASCII.GetString($Bytes, $partStart, $headerEnd - $partStart)
        $headers = @{}
        foreach ($line in ($headerText -split "`r`n")) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $idx = $line.IndexOf(':')
            if ($idx -lt 1) { continue }
            $headers[$line.Substring(0, $idx).Trim().ToLowerInvariant()] = $line.Substring($idx + 1).Trim()
        }

        $disposition = [string]$headers['content-disposition']
        $name = $null; $filename = $null
        if ($disposition -match 'name="([^"]*)"') { $name = $Matches[1] }
        if ($disposition -match 'filename="([^"]*)"') { $filename = $Matches[1] }

        $contentStart = $headerEnd + 4
        $contentLength = $partEnd - $contentStart
        $content = if ($contentLength -gt 0) { [byte[]]::new($contentLength) } else { [byte[]]::new(0) }
        if ($contentLength -gt 0) { [Array]::Copy($Bytes, $contentStart, $content, 0, $contentLength) }

        $parts.Add(@{
                Headers     = $headers
                Name        = $name
                FileName    = $filename
                ContentType = [string]$headers['content-type']
                Content     = $content
            })
    }
    , $parts.ToArray()
}
