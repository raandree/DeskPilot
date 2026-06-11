function Get-DpAtelierHealth {
    <#
    .SYNOPSIS
        Reports the health of the configured Customization roots (the Atelier).
    .DESCRIPTION
        For each Customization category in the catalog (Agents, Skills,
        Instructions, Prompt files) reports every configured root: its path,
        whether it resolves to a directory, how many Customizations of that
        category were discovered in it, whether the path is a reparse point
        (a junction or symlink, as a CopilotAtelier OneDrive+NTFS-junction layout
        uses), and whether a broken/unreadable reparse point was detected. Designed
        never to throw: an unreadable root is reported in its 'error' field. The
        per-root count reuses the same discovery rules as Get-DpCustomizationList
        (flat suffix match, or nested SKILL.md), so the numbers agree with the
        Customizations surface.
    .PARAMETER Settings
        The DeskPilot Settings hashtable.
    .PARAMETER HomeDirectory
        The home directory used to label the 'User' scope. Defaults to $HOME.
    .OUTPUTS
        System.Collections.Hashtable with a 'categories' array and 'okCount' /
        'missingCount' / 'totalRoots' summary fields.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Settings,

        [string]$HomeDirectory = $HOME
    )

    $userRoot = $null
    if (-not [string]::IsNullOrWhiteSpace($HomeDirectory)) {
        try { $userRoot = [System.IO.Path]::GetFullPath((Join-Path $HomeDirectory '.copilot')).TrimEnd('\', '/') } catch { $userRoot = $null }
    }

    $countFiles = {
        param([string]$Root, [hashtable]$Entry)
        try {
            if ($Entry.nested) {
                $files = Get-ChildItem -LiteralPath $Root -Recurse -Filter $Entry.fileName -File -ErrorAction Stop
                return @($files | Where-Object { $_.Name -ieq $Entry.fileName }).Count
            }
            $files = Get-ChildItem -LiteralPath $Root -Filter "*$($Entry.suffix)" -File -ErrorAction Stop
            return @($files | Where-Object { $_.Name.EndsWith($Entry.suffix, [System.StringComparison]::OrdinalIgnoreCase) }).Count
        }
        catch { return -1 }
    }

    $categories = [System.Collections.Generic.List[hashtable]]::new()
    $okCount = 0
    $missingCount = 0
    $totalRoots = 0

    foreach ($entry in Get-DpCustomizationCatalog) {
        $roots = @(Get-DpCustomizationRoot -Settings $Settings -Category $entry.id)
        $rootInfos = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($root in $roots) {
            $totalRoots++
            $info = @{
                path           = $root
                exists         = $false
                count          = 0
                isReparsePoint = $false
                scope          = 'Workspace'
                error          = $null
            }
            if ($userRoot) {
                $compare = $root.TrimEnd('\', '/')
                if ($compare.StartsWith($userRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -or
                    $compare.Equals($userRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $info.scope = 'User'
                }
            }
            try {
                $item = Get-Item -LiteralPath $root -Force -ErrorAction Stop
                $info.exists = $item.PSIsContainer
                $info.isReparsePoint = [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
                if ($info.exists) {
                    $n = & $countFiles $root $entry
                    if ($n -lt 0) { $info.error = 'Could not read the folder.' } else { $info.count = $n }
                }
                else {
                    $info.error = 'Path is not a folder.'
                }
            }
            catch {
                # A broken junction (dangling reparse point) lands here.
                $info.error = 'Missing or unreadable (broken junction?).'
            }
            if ($info.exists -and -not $info.error) { $okCount++ } else { $missingCount++ }
            $rootInfos.Add($info)
        }
        $categories.Add(@{
                id    = $entry.id
                label = $entry.label
                roots = @($rootInfos)
            })
    }

    @{
        categories   = @($categories)
        okCount      = $okCount
        missingCount = $missingCount
        totalRoots   = $totalRoots
    }
}

