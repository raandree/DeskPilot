function Save-DpMemoryStore {
    <#
    .SYNOPSIS
        Persists the Agent Memory store to disk as JSON.
    .DESCRIPTION
        Writes the memory hashtable (text + updatedUtc) to agent-memory.json in the
        given directory. Atomic (temp file then move) and best-effort: a failure is
        written to the error stream but not thrown, matching the other DeskPilot
        stores.
    .PARAMETER Memory
        The memory hashtable to save (keys text and updatedUtc).
    .PARAMETER Directory
        The data directory to write into.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Memory,

        [Parameter(Mandatory)]
        [string]$Directory
    )

    try {
        if (-not (Test-Path -LiteralPath $Directory)) {
            New-Item -ItemType Directory -Path $Directory -Force -ErrorAction Stop | Out-Null
        }
        $payload = @{
            text       = [string]$Memory.text
            updatedUtc = $Memory.updatedUtc
            version    = 1
        } | ConvertTo-Json -Depth 5 -Compress
        $target = Join-Path $Directory 'agent-memory.json'
        $temp = "$target.tmp"
        [System.IO.File]::WriteAllText($temp, $payload, [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temp -Destination $target -Force -ErrorAction Stop
    }
    catch {
        Write-Error "Failed to persist agent memory: $_"
    }
}
