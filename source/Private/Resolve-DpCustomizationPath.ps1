function Resolve-DpCustomizationPath {
    <#
    .SYNOPSIS
        Validates that a path is an editable Customization inside a configured root.
    .DESCRIPTION
        The single security gate every Customization read and write passes through.
        It confirms three things, in order: the category is known; the resolved
        path is a descendant of one of that category's configured root folders
        (a case-insensitive prefix test on a directory-separator boundary, so a
        sibling folder with a shared prefix or a '..' escape is refused); and the
        file name matches the category's expected pattern (a suffix such as
        '.agent.md' for flat categories, or exactly 'SKILL.md' for skills). It does
        NOT require the file to exist - callers add that check when they need it
        (a read or a save targets an existing file; a create targets a new one).
    .PARAMETER Settings
        The DeskPilot Settings hashtable.
    .PARAMETER Category
        The category id (agent, skill, instruction or prompt).
    .PARAMETER Path
        The absolute path to validate.
    .OUTPUTS
        System.Collections.Hashtable with ok, full, root, category and error.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Settings,

        [Parameter(Mandatory)]
        [string]$Category,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $result = @{ ok = $false; full = $null; root = $null; category = $Category; error = $null }

    $entry = Get-DpCustomizationCatalog | Where-Object { $_.id -eq $Category } | Select-Object -First 1
    if (-not $entry) { $result.error = "Unknown category '$Category'."; return $result }

    if ([string]::IsNullOrWhiteSpace($Path)) { $result.error = 'A file path is required.'; return $result }

    try { $full = [System.IO.Path]::GetFullPath($Path) }
    catch { $result.error = 'Invalid path.'; return $result }
    $result.full = $full

    # Must sit inside one of the configured roots (separator-boundary prefix test).
    $fullCompare = $full.TrimEnd('\', '/')
    $matchedRoot = $null
    foreach ($root in @(Get-DpCustomizationRoot -Settings $Settings -Category $Category)) {
        $rootCompare = $root.TrimEnd('\', '/')
        if ($fullCompare.StartsWith($rootCompare + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
            $matchedRoot = $root
            break
        }
    }
    if (-not $matchedRoot) { $result.error = 'Outside the configured folders.'; return $result }
    $result.root = $matchedRoot

    # File-name pattern guard so only genuine Customization files are touched.
    $leaf = Split-Path -Leaf $full
    $patternOk = if ($entry.nested) {
        $leaf -ieq $entry.fileName
    }
    else {
        $leaf.EndsWith($entry.suffix, [System.StringComparison]::OrdinalIgnoreCase) -and $leaf.Length -gt $entry.suffix.Length
    }
    if (-not $patternOk) {
        $expected = if ($entry.nested) { $entry.fileName } else { "*$($entry.suffix)" }
        $result.error = "Not a valid $Category file (expected $expected)."
        return $result
    }

    $result.ok = $true
    $result
}
