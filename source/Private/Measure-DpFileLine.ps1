function Measure-DpFileLine {
    <#
    .SYNOPSIS
        Counts the lines of a file and detects binary content.
    .DESCRIPTION
        Used for untracked files, which have no diff against HEAD but should still
        show a line count in the Changes panel. Reads at most MaxBytes so a huge
        file cannot stall the Host Server, treats an embedded NUL byte as binary,
        and never throws: an unreadable or missing file reports zero lines.
    .PARAMETER Path
        The file to measure.
    .PARAMETER MaxBytes
        The maximum number of bytes to read.
    .OUTPUTS
        System.Collections.Hashtable with lines, binary and truncated.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [int]$MaxBytes = 2MB
    )

    $result = @{ lines = 0; binary = $false; truncated = $false }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $result }

    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try {
            $length = [int][System.Math]::Min([long]$MaxBytes, $stream.Length)
            $result.truncated = ($stream.Length -gt $length)
            $buffer = [byte[]]::new($length)
            $read = 0
            while ($read -lt $length) {
                $chunk = $stream.Read($buffer, $read, $length - $read)
                if ($chunk -le 0) { break }
                $read += $chunk
            }
            $newlines = 0
            $lastByte = 0
            for ($i = 0; $i -lt $read; $i++) {
                $b = $buffer[$i]
                if ($b -eq 0) { $result.binary = $true; $result.lines = 0; return $result }
                if ($b -eq 10) { $newlines++ }
                $lastByte = $b
            }
            # A trailing line without a newline still counts as a line.
            $result.lines = if ($read -eq 0) { 0 } elseif ($lastByte -eq 10) { $newlines } else { $newlines + 1 }
        }
        finally { $stream.Dispose() }
    }
    catch { return @{ lines = 0; binary = $false; truncated = $false } }

    $result
}
