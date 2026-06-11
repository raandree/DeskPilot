function Import-DpSettings {
    <#
    .SYNOPSIS
        Loads persisted Settings from disk, merged onto the defaults.
    .DESCRIPTION
        Reads settings.json from the given directory and merges the persisted
        keys onto Get-DpDefaultSettings so a partial or older file still loads.
        Returns the defaults when the file is missing or unreadable. Merging
        goes through Merge-DpSettings so the same validation runs.
    .PARAMETER Directory
        The data directory to read from.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Directory
    )

    $defaults = Get-DpDefaultSettings
    $path = Join-Path $Directory 'settings.json'
    if (-not (Test-Path -LiteralPath $path)) { return $defaults }

    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $defaults }
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
        if ($null -ne $parsed) {
            if ($parsed -is [System.Collections.IDictionary]) { $parsed.Remove('version') }
            elseif ($parsed.PSObject.Properties['version']) { $parsed.PSObject.Properties.Remove('version') | Out-Null }
        }
        $merged = Merge-DpSettings -Current $defaults -Patch $parsed
        # Backfill the Copilot-derived roots when a persisted file left them empty
        # (for example an older settings.json), so the ~/.copilot defaults apply.
        if (@($merged.skillRoots).Count -eq 0) { $merged.skillRoots = @($defaults.skillRoots) }
        if (@($merged.instructionRoots).Count -eq 0) { $merged.instructionRoots = @($defaults.instructionRoots) }
        if (@($merged.promptRoots).Count -eq 0) { $merged.promptRoots = @($defaults.promptRoots) }
        if (-not $merged.agentsRoot) { $merged.agentsRoot = $defaults.agentsRoot }
        return $merged
    }
    catch {
        Write-Error "Failed to load settings (using defaults): $_"
        return $defaults
    }
}
