function Save-DpSettings {
    <#
    .SYNOPSIS
        Persists Settings to disk as JSON.
    .DESCRIPTION
        Writes the Settings hashtable to settings.json in the given directory.
        Atomic (temp file then move) and best-effort: a failure is written to the
        error stream but not thrown.
    .PARAMETER Settings
        The Settings hashtable to save.
    .PARAMETER Directory
        The data directory to write into.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Settings,

        [Parameter(Mandatory)]
        [string]$Directory
    )

    try {
        if (-not (Test-Path -LiteralPath $Directory)) {
            New-Item -ItemType Directory -Path $Directory -Force -ErrorAction Stop | Out-Null
        }
        $payload = ($Settings + @{ version = 1 }) | ConvertTo-Json -Depth 10 -Compress
        $target = Join-Path $Directory 'settings.json'
        $temp = "$target.tmp"
        [System.IO.File]::WriteAllText($temp, $payload, [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temp -Destination $target -Force -ErrorAction Stop
    }
    catch {
        Write-Error "Failed to persist settings: $_"
    }
}
