function Add-DpChangeEntry {
    <#
    .SYNOPSIS
        Records the files a Turn wrote, against the snapshot taken before it ran.
    .DESCRIPTION
        Merges a Turn's written files into the Project's pending change set. A file
        already tracked keeps its ORIGINAL snapshot: after three Turns edit the
        same file, "undo" has to mean "back to how it was before DeskPilot first
        touched it", not "back to how it was one Turn ago". Paths are confined to
        the Project folder, so a write the agent made elsewhere is never recorded
        as something this Project can undo. Never throws.
    .PARAMETER Store
        The change set, keyed by normalized Project folder; updated in place.
    .PARAMETER Root
        The Project (Workspace) folder.
    .PARAMETER Paths
        The files the Turn wrote (relative to Root or absolute inside it).
    .PARAMETER SnapshotSha
        The snapshot commit taken before the Turn, or empty when there is none.
    .PARAMETER ConversationId
        The Conversation the Turn belonged to.
    .OUTPUTS
        System.Int32 - how many files were newly tracked.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Store,

        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Paths,

        [string]$SnapshotSha,

        [string]$ConversationId
    )

    if ([string]::IsNullOrWhiteSpace($Root)) { return 0 }
    try { $rootFull = [System.IO.Path]::GetFullPath($Root) } catch { return 0 }
    $rootTrim = $rootFull.TrimEnd('\', '/')
    $key = $rootTrim

    # Built then filled, never returned from an if-expression: PowerShell unrolls
    # an empty collection to nothing, which would leave this null.
    $existing = [System.Collections.Generic.List[hashtable]]::new()
    if ($Store.ContainsKey($key)) {
        foreach ($item in @($Store[$key])) { if ($item) { $existing.Add([hashtable]$item) } }
    }
    $known = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $existing) { [void]$known.Add([string]$entry.rel) }

    $added = 0
    foreach ($path in @($Paths)) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        $candidate = if ([System.IO.Path]::IsPathRooted($path)) { $path } else { Join-Path $rootFull $path }
        try { $full = [System.IO.Path]::GetFullPath($candidate) } catch { continue }
        $fullCompare = $full.TrimEnd('\', '/')
        if (-not $fullCompare.StartsWith($rootTrim + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $rel = $fullCompare.Substring($rootTrim.Length).TrimStart('\', '/') -replace '\\', '/'
        if ($known.Contains($rel)) { continue }
        [void]$known.Add($rel)
        $existing.Add(@{
                rel            = $rel
                snapshotSha    = [string]$SnapshotSha
                conversationId = [string]$ConversationId
                firstSeenUtc   = [DateTime]::UtcNow.ToString('o')
            })
        $added++
    }

    if ($existing.Count -gt 0) { $Store[$key] = @($existing) }
    elseif ($Store.ContainsKey($key)) { $null = $Store.Remove($key) }
    $added
}
