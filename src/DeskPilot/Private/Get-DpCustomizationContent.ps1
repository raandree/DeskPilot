function Get-DpCustomizationContent {
    <#
    .SYNOPSIS
        Reads a Customization file's text for the editor.
    .DESCRIPTION
        Validates the path with Resolve-DpCustomizationPath (so only a genuine
        Customization inside a configured root can be read), then returns the
        file's UTF-8 text. A file larger than MaxBytes is read only up to that cap
        and flagged 'truncated' (the editor opens such a file read-only so an edit
        cannot silently drop the tail). A file whose inspected bytes contain a NUL
        is treated as binary and returned without text. Validation and read
        failures are reported in 'error'.
    .PARAMETER Settings
        The DeskPilot Settings hashtable.
    .PARAMETER Category
        The category id (agent, skill, instruction or prompt).
    .PARAMETER Path
        The absolute path of the Customization file to read.
    .PARAMETER MaxBytes
        The most bytes to read as text. Larger files are truncated to this size.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Settings,

        [Parameter(Mandatory)]
        [string]$Category,

        [Parameter(Mandatory)]
        [string]$Path,

        [int]$MaxBytes = 1048576
    )

    $result = @{ category = $Category; path = $null; name = $null; bytes = 0; truncated = $false; binary = $false; text = ''; error = $null }

    $resolved = Resolve-DpCustomizationPath -Settings $Settings -Category $Category -Path $Path
    $result.path = $resolved.full
    if (-not $resolved.ok) { $result.error = $resolved.error; return $result }

    $full = $resolved.full
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { $result.error = 'File not found.'; return $result }

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

            $sniff = [Math]::Min($readLen, 8000)
            for ($i = 0; $i -lt $sniff; $i++) {
                if ($buffer[$i] -eq 0) { $result.binary = $true; break }
            }
        }

        if (-not $result.binary) {
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
