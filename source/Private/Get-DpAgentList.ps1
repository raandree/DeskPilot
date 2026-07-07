function Get-DpAgentList {
    <#
    .SYNOPSIS
        Lists the Agents (*.agent.md files) discovered under a root folder.
    .DESCRIPTION
        Returns one record per *.agent.md file with a stable id (the file name),
        a display name (the frontmatter 'name', or the file's stem), an optional
        description, and the full path. Returns an empty array when the root is
        unset or missing.
    .PARAMETER Root
        The Agents folder to scan (typically ~/.copilot/agents).
    .OUTPUTS
        System.Collections.Hashtable[]
    #>
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param(
        [string]$Root
    )

    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root -PathType Container -ErrorAction SilentlyContinue)) {
        return @()
    }

    $files = Get-ChildItem -LiteralPath $Root -Filter '*.agent.md' -File -ErrorAction SilentlyContinue | Sort-Object Name
    $list = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($file in $files) {
        $stem = $file.Name -replace '\.agent\.md$', ''
        $meta = $null
        try { $meta = Read-DpAgentFile -Path $file.FullName } catch { $meta = $null }
        $displayName = if ($meta -and $meta.name) { $meta.name } else { $stem }
        $list.Add(@{
                id          = $file.Name
                name        = $displayName
                description = if ($meta) { $meta.description } else { $null }
                path        = $file.FullName
            })
    }
    $list.ToArray()
}
