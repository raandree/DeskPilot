function Get-DpCustomizationRoot {
    <#
    .SYNOPSIS
        Resolves the configured root folder(s) for a Customization category.
    .DESCRIPTION
        Reads the Settings key named by the category's catalog entry and returns
        the configured root path(s) as full, de-duplicated paths. The agent
        category holds a single root (a string); the skill, instruction and prompt
        categories hold an array of roots. Blank entries are dropped. The returned
        paths are normalised with GetFullPath but are NOT required to exist on disk
        - callers that enumerate skip missing roots, and New-DpCustomization creates
        a configured root on demand.
    .PARAMETER Settings
        The DeskPilot Settings hashtable.
    .PARAMETER Category
        The category id (agent, skill, instruction or prompt).
    .OUTPUTS
        System.String[] - zero or more root paths.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Settings,

        [Parameter(Mandatory)]
        [string]$Category
    )

    $entry = Get-DpCustomizationCatalog | Where-Object { $_.id -eq $Category } | Select-Object -First 1
    if (-not $entry) { return @() }

    $key = $entry.rootSetting
    if (-not $Settings.ContainsKey($key)) { return @() }
    $raw = $Settings[$key]

    $candidates = if ($entry.single) { @($raw) } else { @($raw) }
    $seen = @{}
    $result = [System.Collections.Generic.List[string]]::new()
    foreach ($candidate in $candidates) {
        if ($null -eq $candidate) { continue }
        $path = ([string]$candidate).Trim()
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        try { $full = [System.IO.Path]::GetFullPath($path) } catch { continue }
        $dedupKey = $full.TrimEnd('\', '/').ToLowerInvariant()
        if ($seen.ContainsKey($dedupKey)) { continue }
        $seen[$dedupKey] = $true
        $result.Add($full)
    }
    $result.ToArray()
}
