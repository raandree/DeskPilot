function Test-DpBinaryFile {
    <#
    .SYNOPSIS
        Reports whether a file looks binary and should be skipped by a text search.
    .DESCRIPTION
        Reads the first block and answers "binary" on a NUL byte, which is the
        same heuristic git uses. It is cheap, it never decodes the file, and it
        is right about the cases that matter: an executable, an archive or an
        image returned as a "match" spends the model's context on noise it cannot
        read.

        A leading UTF-16 or UTF-32 byte-order mark is the one exception. Those
        encodings are full of NUL bytes yet decode perfectly, and Windows
        PowerShell wrote UTF-16 by default - skipping them would quietly hide a
        whole class of script from every text search.

        An unreadable or missing file is reported as binary, because the only use
        of this answer is "skip it", and a file that cannot be opened is a file
        that cannot be searched either.
    .PARAMETER Path
        The full path to test.
    .PARAMETER SampleBytes
        How much of the head to inspect.
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [ValidateRange(1, 1048576)]
        [int]$SampleBytes = 8192
    )

    $stream = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $buffer = [byte[]]::new($SampleBytes)
        $read = $stream.Read($buffer, 0, $SampleBytes)
        if ($read -ge 2 -and (($buffer[0] -eq 0xFF -and $buffer[1] -eq 0xFE) -or ($buffer[0] -eq 0xFE -and $buffer[1] -eq 0xFF))) { return $false }
        if ($read -ge 4 -and $buffer[0] -eq 0 -and $buffer[1] -eq 0 -and $buffer[2] -eq 0xFE -and $buffer[3] -eq 0xFF) { return $false }
        for ($i = 0; $i -lt $read; $i++) {
            if ($buffer[$i] -eq 0) { return $true }
        }
        $false
    }
    catch {
        $openError = $_
        Write-Verbose "Could not sample '$Path': $openError"
        $true
    }
    finally {
        if ($stream) { $stream.Dispose() }
    }
}
