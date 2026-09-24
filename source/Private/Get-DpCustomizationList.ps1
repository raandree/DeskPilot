function Get-DpCustomizationList {
    <#
    .SYNOPSIS
        Lists every Customization discovered under the configured roots.
    .DESCRIPTION
        Walks each category in the catalog and enumerates its files from the
        configured root folder(s): flat categories (agent, instruction, prompt)
        match files whose name ends with the category suffix directly under a root;
        the skill category matches every 'SKILL.md' found beneath a root and names
        the skill after the folder that holds it. Each item carries a display name
        (the frontmatter 'name' when present, otherwise the file/folder stem), the
        frontmatter description, its absolute path, the root it came from, and a
        scope label ('User' for files under ~/.copilot, otherwise 'Workspace').
        Missing roots are skipped. The result groups items by category in catalog
        order with a per-category count.

        A skill item carries three more fields, from Get-DpSkillConformance: the
        bounded 'metadata' the SKILL.md actually declares, the 'warnings' worth
        repairing, and 'conformant'. Where two skills share a name, both are
        listed and both are told about it: 'precedence' is 'primary' for the copy
        in the earlier configured root and 'shadowed' for the later one. That is
        DeskPilot's listing order only - which Skill an agent loads is decided by
        the Engine's own discovery.
    .PARAMETER Settings
        The DeskPilot Settings hashtable.
    .PARAMETER HomeDirectory
        The home directory used to classify the 'User' scope. Defaults to $HOME;
        overridable for tests.
    .OUTPUTS
        System.Collections.Hashtable with a 'categories' array.
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

    $scopeOf = {
        param([string]$Path)
        if ($userRoot) {
            $compare = $Path.TrimEnd('\', '/')
            if ($compare.StartsWith($userRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -or
                $compare.Equals($userRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                return 'User'
            }
        }
        'Workspace'
    }

    $readMeta = {
        param([string]$Path)
        # Read-DpAgentFile is a generic Markdown-frontmatter reader (name +
        # description + body) despite its name; reuse it for every category.
        try { return Read-DpAgentFile -Path $Path } catch { return $null }
    }

    $categories = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($entry in Get-DpCustomizationCatalog) {
        $roots = @(Get-DpCustomizationRoot -Settings $Settings -Category $entry.id)
        $items = [System.Collections.Generic.List[hashtable]]::new()

        foreach ($root in $roots) {
            $rootIndex = [array]::IndexOf($roots, $root)
            if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }

            if ($entry.nested) {
                $files = Get-ChildItem -LiteralPath $root -Recurse -Filter $entry.fileName -File -ErrorAction SilentlyContinue
                foreach ($file in $files) {
                    if ($file.Name -ine $entry.fileName) { continue }
                    $folderName = Split-Path -Leaf (Split-Path -Parent $file.FullName)
                    # A Skill is measured against the Agent Skills specification
                    # while it is listed: metadata only, never the body. One
                    # unreadable Skill must not cost the user the whole catalog.
                    $skill = $null
                    try { $skill = Get-DpSkillConformance -Path $file.FullName -Root $root } catch { $skill = $null }
                    if (-not $skill) {
                        $skill = @{
                            directory   = $folderName
                            name        = $folderName
                            description = $null
                            metadata    = @{}
                            resources   = @{ scripts = $false; references = $false; assets = $false }
                            warnings    = @(@{ code = 'unreadable'; severity = 'error'; message = 'DeskPilot could not read this SKILL.md.' })
                            conformant  = $false
                        }
                    }
                    $name = if ($skill.name) { $skill.name } else { $folderName }
                    $items.Add(@{
                            id          = $file.FullName
                            category    = $entry.id
                            name        = $name
                            description = $skill.description
                            path        = $file.FullName
                            root        = $root
                            scope       = (& $scopeOf $file.FullName)
                            directory   = $skill.directory
                            metadata    = $skill.metadata
                            resources   = $skill.resources
                            warnings    = @($skill.warnings)
                            conformant  = $skill.conformant
                            precedence  = 'primary'
                            rootOrder   = $rootIndex
                        })
                }
            }
            else {
                $files = Get-ChildItem -LiteralPath $root -Filter "*$($entry.suffix)" -File -ErrorAction SilentlyContinue
                foreach ($file in $files) {
                    if (-not $file.Name.EndsWith($entry.suffix, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
                    $stem = $file.Name.Substring(0, $file.Name.Length - $entry.suffix.Length)
                    $meta = & $readMeta $file.FullName
                    $name = if ($meta -and $meta.name) { $meta.name } else { $stem }
                    $items.Add(@{
                            id          = $file.FullName
                            category    = $entry.id
                            name        = $name
                            description = if ($meta) { $meta.description } else { $null }
                            path        = $file.FullName
                            root        = $root
                            scope       = (& $scopeOf $file.FullName)
                        })
                }
            }
        }

        if ($entry.nested) {
            # Two Skills answering to one name is an ambiguity the user has to
            # resolve, so say it on both copies rather than quietly dropping one.
            # The configured root order decides what DeskPilot lists first; the
            # Engine decides what an agent actually loads.
            foreach ($group in ($items | Group-Object -Property { ([string]$_.name).Trim().ToLowerInvariant() })) {
                if ($group.Count -lt 2) { continue }
                $ordered = @($group.Group | Sort-Object @{ Expression = { $_.rootOrder } }, @{ Expression = { $_.path } })
                $winner = $ordered[0]
                foreach ($copy in $ordered) {
                    if ($copy -ne $winner) { $copy.precedence = 'shadowed' }
                    $others = @($ordered | Where-Object { $_ -ne $copy } | ForEach-Object { $_.root })
                    $copy.warnings = @($copy.warnings) + @(@{
                            code     = 'duplicate-name'
                            severity = 'warning'
                            message  = "More than one Skill is called '$($copy.name)' ($($others -join ', ')). DeskPilot lists the copy in $($winner.root) first; which one an agent loads is decided by the Engine's own discovery, not by this list."
                        })
                }
            }
        }

        $sorted = @($items | Sort-Object @{ Expression = { $_.name } }, @{ Expression = { $_.path } })
        foreach ($item in $sorted) { $item.Remove('rootOrder') }
        $categories.Add(@{
                id    = $entry.id
                label = $entry.label
                count = $sorted.Count
                roots = @($roots)
                items = $sorted
            })
    }

    @{ categories = @($categories) }
}
