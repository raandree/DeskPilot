function Save-DpLifetimeUsage {
    <#
    .SYNOPSIS
        Persists the lifetime Usage counter to disk as JSON.
    .DESCRIPTION
        Writes the lifetime Usage hashtable to lifetime-usage.json in the given
        directory. Atomic (temp file then move) and best-effort: a failure is
        written to the error stream but not thrown.
    .PARAMETER Usage
        The lifetime Usage hashtable.
    .PARAMETER Directory
        The data directory to write into.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Usage,

        [Parameter(Mandatory)]
        [string]$Directory
    )

    try {
        if (-not (Test-Path -LiteralPath $Directory)) {
            New-Item -ItemType Directory -Path $Directory -Force -ErrorAction Stop | Out-Null
        }
        $payload = ($Usage + @{ version = 1 }) | ConvertTo-Json -Depth 6 -Compress
        $target = Join-Path $Directory 'lifetime-usage.json'
        $temp = "$target.tmp"
        [System.IO.File]::WriteAllText($temp, $payload, [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temp -Destination $target -Force -ErrorAction Stop
    }
    catch {
        Write-Error "Failed to persist lifetime usage: $_"
    }
}
