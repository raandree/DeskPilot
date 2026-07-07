function Import-DpMemoryStore {
    <#
    .SYNOPSIS
        Loads the persisted Agent Memory store from disk.
    .DESCRIPTION
        Reads agent-memory.json from the given directory and returns a hashtable
        with the memory text and the UTC timestamp of its last update. Returns an
        empty store when the file is missing or unreadable, so a first run and a
        corrupt file both degrade gracefully. The text is capped to the Agent
        Memory limit on load in case an older or hand-edited file exceeds it.
    .PARAMETER Directory
        The data directory to read from.
    .OUTPUTS
        System.Collections.Hashtable with keys text and updatedUtc.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Directory
    )

    $empty = @{ text = ''; updatedUtc = $null }
    $path = Join-Path $Directory 'agent-memory.json'
    if (-not (Test-Path -LiteralPath $path)) { return $empty }

    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $empty }
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
        $text = [string](Get-DpPropertyValue -InputObject $parsed -Name @('text', 'Text') -Default '')
        # ConvertFrom-Json coerces an ISO timestamp string into a [DateTime], which
        # [string] would then reformat in the current culture; normalise it back to
        # a round-trippable ISO-8601 UTC string (as the conversation/usage stores do).
        $updated = ConvertTo-DpIsoString -Value (Get-DpPropertyValue -InputObject $parsed -Name @('updatedUtc', 'UpdatedUtc') -Default $null)
        $cap = (Get-DpMemoryLimits).agentMemory
        if ($text.Length -gt $cap) { $text = $text.Substring(0, $cap) }
        return @{ text = $text; updatedUtc = $(if ($updated) { $updated } else { $null }) }
    }
    catch {
        Write-Error "Failed to load agent memory (using empty): $_"
        return $empty
    }
}
