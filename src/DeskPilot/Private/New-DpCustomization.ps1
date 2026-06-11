function New-DpCustomization {
    <#
    .SYNOPSIS
        Creates a new, scaffolded Customization file in a configured root.
    .DESCRIPTION
        Validates the requested Name as a single safe path segment (letters,
        digits, dot, dash and underscore only - no separators or '..'), picks the
        target root (the supplied Root when it is one of the category's configured
        roots, otherwise the first configured root), and writes a starter file from
        the category's catalog scaffold. Flat categories create '<root>/<Name><suffix>';
        the skill category creates the folder '<root>/<Name>' with a 'SKILL.md'
        inside. The derived path is re-checked with Resolve-DpCustomizationPath as a
        final guard. Throws when no root is configured, when the Name is invalid, or
        when the target already exists, so the caller can map it to an HTTP 400.
    .PARAMETER Settings
        The DeskPilot Settings hashtable.
    .PARAMETER Category
        The category id (agent, skill, instruction or prompt).
    .PARAMETER Name
        The new Customization's name (a single path segment).
    .PARAMETER Root
        Optional target root; must be one of the category's configured roots.
    .OUTPUTS
        System.Collections.Hashtable with category, name, path and root.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Settings,

        [Parameter(Mandatory)]
        [string]$Category,

        [Parameter(Mandatory)]
        [string]$Name,

        [string]$Root
    )

    $entry = Get-DpCustomizationCatalog | Where-Object { $_.id -eq $Category } | Select-Object -First 1
    if (-not $entry) { throw "Unknown category '$Category'." }

    $trimmed = ([string]$Name).Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) { throw 'A name is required.' }
    if ($trimmed -eq '.' -or $trimmed -eq '..') { throw "Invalid name '$trimmed'." }
    if ($trimmed -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        throw "Invalid name '$trimmed'. Use only letters, digits, dot, dash and underscore."
    }
    if ($trimmed.Length -gt 100) { throw 'The name is too long (max 100 characters).' }

    $roots = @(Get-DpCustomizationRoot -Settings $Settings -Category $Category)
    if (-not $roots.Count) { throw "Configure a $($entry.label) folder in Settings before creating one." }

    $targetRoot = $roots[0]
    if (-not [string]::IsNullOrWhiteSpace($Root)) {
        $wanted = $null
        try { $wanted = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/') } catch { $wanted = $null }
        $match = $roots | Where-Object { $_.TrimEnd('\', '/').Equals($wanted, [System.StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
        if (-not $match) { throw 'The chosen folder is not a configured root for this category.' }
        $targetRoot = $match
    }

    if (-not (Test-Path -LiteralPath $targetRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $targetRoot -Force | Out-Null
    }

    if ($entry.nested) {
        $folder = Join-Path $targetRoot $trimmed
        $target = Join-Path $folder $entry.fileName
    }
    else {
        $folder = $targetRoot
        $target = Join-Path $targetRoot ($trimmed + $entry.suffix)
    }

    # Final defence in depth: the derived path must satisfy the security gate.
    $resolved = Resolve-DpCustomizationPath -Settings $Settings -Category $Category -Path $target
    if (-not $resolved.ok) { throw $resolved.error }

    if (Test-Path -LiteralPath $target -PathType Leaf) {
        throw "A $Category named '$trimmed' already exists."
    }

    if ($entry.nested -and -not (Test-Path -LiteralPath $folder -PathType Container)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }

    $scaffold = $entry.scaffold -f $trimmed
    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllBytes($resolved.full, $encoding.GetBytes($scaffold))

    @{ category = $Category; name = $trimmed; path = $resolved.full; root = $targetRoot }
}
