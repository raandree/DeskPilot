function Remove-DpChangeEntry {
    <#
    .SYNOPSIS
        Stops tracking files as pending AI changes, and drops orphaned snapshots.
    .DESCRIPTION
        The "keep" side of the review, and the cleanup after an undo: the entries
        are removed from the Project's change set, and any snapshot ref no longer
        referenced by a remaining entry is deleted so the repository does not
        accumulate them. Keeping a change does not commit it - it only stops
        DeskPilot presenting it as unreviewed; the file stays exactly as it is.
        Never throws.
    .PARAMETER Store
        The change set, keyed by normalized Project folder; updated in place.
    .PARAMETER Root
        The Project (Workspace) folder.
    .PARAMETER Paths
        The files to stop tracking. Omit to clear the Project's whole set.
    .OUTPUTS
        System.Collections.Hashtable with cleared and remaining.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Store,

        [Parameter(Mandatory)]
        [string]$Root,

        [string[]]$Paths
    )

    $result = @{ cleared = 0; remaining = 0 }

    if ([string]::IsNullOrWhiteSpace($Root)) { return $result }
    try { $rootFull = [System.IO.Path]::GetFullPath($Root) } catch { return $result }
    $key = $rootFull.TrimEnd('\', '/')
    if (-not $Store.ContainsKey($key)) { return $result }

    $wanted = $null
    if ($PSBoundParameters.ContainsKey('Paths')) {
        $wanted = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($p in @($Paths)) { if (-not [string]::IsNullOrWhiteSpace($p)) { [void]$wanted.Add(($p -replace '\\', '/')) } }
    }

    $before = @($Store[$key])
    $keptShas = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $droppedShas = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $remaining = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($entry in $before) {
        if (-not $entry) { continue }
        $rel = [string](Get-DpPropertyValue -InputObject $entry -Name @('rel') -Default '')
        $sha = [string](Get-DpPropertyValue -InputObject $entry -Name @('snapshotSha') -Default '')
        if ($wanted -and -not $wanted.Contains($rel)) {
            $remaining.Add($entry)
            if ($sha) { [void]$keptShas.Add($sha) }
            continue
        }
        $result.cleared++
        if ($sha) { [void]$droppedShas.Add($sha) }
    }

    if ($remaining.Count -gt 0) { $Store[$key] = @($remaining) } else { $null = $Store.Remove($key) }
    $result.remaining = $remaining.Count

    foreach ($sha in $droppedShas) {
        if ($keptShas.Contains($sha)) { continue }
        $refs = Invoke-DpGitCommand -Path $rootFull -Arguments @('for-each-ref', '--format=%(refname) %(objectname)', 'refs/deskpilot/snapshots')
        if (-not $refs.Ok) { break }
        foreach ($line in ($refs.StdOut -split '\r?\n')) {
            $parts = $line.Trim() -split '\s+'
            if ($parts.Count -lt 2) { continue }
            if ($parts[1] -eq $sha) { $null = Invoke-DpGitCommand -Path $rootFull -Arguments @('update-ref', '-d', $parts[0]) }
        }
    }

    $result
}
