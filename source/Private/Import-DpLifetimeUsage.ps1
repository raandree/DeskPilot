function Import-DpLifetimeUsage {
    <#
    .SYNOPSIS
        Loads the persisted lifetime Usage counter from disk.
    .DESCRIPTION
        Reads lifetime-usage.json from the given directory and returns the
        lifetime Usage hashtable. Returns a fresh zeroed counter (see
        New-DpLifetimeUsage) when the file is missing or unreadable, and fills in
        any missing field so an older or partial file still loads cleanly.
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

    $usage = New-DpLifetimeUsage
    $path = Join-Path $Directory 'lifetime-usage.json'
    if (-not (Test-Path -LiteralPath $path)) { return $usage }

    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $usage }
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
        foreach ($key in @('promptTokens', 'completionTokens', 'totalTokens', 'turns')) {
            if ($parsed.PSObject.Properties[$key]) { $usage[$key] = [int]$parsed.$key }
        }
        foreach ($key in @('costUSD', 'credits')) {
            # Round on load to heal any historical floating-point drift.
            if ($parsed.PSObject.Properties[$key]) { $usage[$key] = [math]::Round([double]$parsed.$key, 6) }
        }
        if ($parsed.PSObject.Properties['sinceUtc'] -and $parsed.sinceUtc) {
            $usage.sinceUtc = ConvertTo-DpIsoString $parsed.sinceUtc
        }
        if ($parsed.PSObject.Properties['daily'] -and $parsed.daily) {
            $usage.daily = @(foreach ($d in @($parsed.daily)) {
                    if (-not $d) { continue }
                    @{
                        date        = [string]$d.date
                        credits     = [math]::Round([double]$d.credits, 4)
                        costUSD     = [math]::Round([double]$d.costUSD, 6)
                        totalTokens = [int]$d.totalTokens
                        turns       = [int]$d.turns
                    }
                })
        }
    }
    catch {
        Write-Error "Failed to load lifetime usage: $_"
    }
    $usage
}
