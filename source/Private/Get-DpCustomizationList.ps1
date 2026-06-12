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
            if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }

            if ($entry.nested) {
                $files = Get-ChildItem -LiteralPath $root -Recurse -Filter $entry.fileName -File -ErrorAction SilentlyContinue
                foreach ($file in $files) {
                    if ($file.Name -ine $entry.fileName) { continue }
                    $folderName = Split-Path -Leaf (Split-Path -Parent $file.FullName)
                    $meta = & $readMeta $file.FullName
                    $name = if ($meta -and $meta.name) { $meta.name } else { $folderName }
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

        $sorted = @($items | Sort-Object @{ Expression = { $_.name } }, @{ Expression = { $_.path } })
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
