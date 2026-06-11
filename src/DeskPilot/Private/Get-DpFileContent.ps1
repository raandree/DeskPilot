function Get-DpFileContent {
    <#
    .SYNOPSIS
        Reads a single text file for the explorer's file viewer.
    .DESCRIPTION
        Returns the UTF-8 text of a file confined to (or equal to a descendant
        of) Root - a path that escapes Root returns an access error - so the
        viewer stays scoped to the selected Project, exactly like the directory
        listing. Files larger than MaxBytes are read only up to that cap and
        flagged 'truncated'. Files whose inspected bytes contain a NUL are
        treated as binary and returned without text. Read failures are reported
        in 'error'.
    .PARAMETER Root
        The Project folder the read is confined to.
    .PARAMETER Path
        The absolute path of the file to read.
    .PARAMETER MaxBytes
        The most bytes to read as text. Larger files are truncated to this size.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [string]$Path,

        [int]$MaxBytes = 1048576
    )

    $result = @{ path = $null; name = $null; bytes = 0; truncated = $false; binary = $false; text = ''; error = $null }

    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root -PathType Container)) {
        $result.error = 'No project folder.'
        return $result
    }
    if ([string]::IsNullOrWhiteSpace($Path)) {
        $result.error = 'No file path.'
        return $result
    }

    $rootFull = [System.IO.Path]::GetFullPath($Root)
    try {
        $full = [System.IO.Path]::GetFullPath($Path)
    }
    catch {
        $result.error = 'Invalid path.'
        return $result
    }

    # Confine to the Project root (case-insensitive prefix on a separator boundary).
    $rootCompare = $rootFull.TrimEnd('\', '/')
    $fullCompare = $full.TrimEnd('\', '/')
    $inside = $fullCompare.StartsWith($rootCompare + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
    if (-not $inside) {
        $result.path = $rootFull
        $result.error = 'Outside the project folder.'
        return $result
    }

    $result.path = $full
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        $result.error = 'File not found.'
        return $result
    }

    try {
        $item = Get-Item -LiteralPath $full -ErrorAction Stop
        $result.name = $item.Name
        $result.bytes = [long]$item.Length

        $cap = [Math]::Max(0, $MaxBytes)
        $readLen = [int][Math]::Min([long]$cap, $item.Length)
        $result.truncated = $item.Length -gt $cap

        $buffer = New-Object byte[] $readLen
        if ($readLen -gt 0) {
            $fs = [System.IO.File]::Open($full, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try {
                $offset = 0
                while ($offset -lt $readLen) {
                    $got = $fs.Read($buffer, $offset, $readLen - $offset)
                    if ($got -le 0) { break }
                    $offset += $got
                }
            }
            finally { $fs.Dispose() }

            # Binary sniff: a NUL byte in the inspected region means "not text".
            $sniff = [Math]::Min($readLen, 8000)
            for ($i = 0; $i -lt $sniff; $i++) {
                if ($buffer[$i] -eq 0) { $result.binary = $true; break }
            }
        }

        if (-not $result.binary) {
            # Strip a UTF-8 BOM if present, then decode the rest as UTF-8.
            $start = 0
            if ($readLen -ge 3 -and $buffer[0] -eq 0xEF -and $buffer[1] -eq 0xBB -and $buffer[2] -eq 0xBF) { $start = 3 }
            $result.text = [System.Text.Encoding]::UTF8.GetString($buffer, $start, $readLen - $start)
        }
    }
    catch {
        $result.error = "$($_.Exception.Message)"
    }
    $result
}
