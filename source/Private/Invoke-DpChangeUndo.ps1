function Invoke-DpChangeUndo {
    <#
    .SYNOPSIS
        Puts files back the way they were before DeskPilot touched them.
    .DESCRIPTION
        Restores each requested file from the snapshot recorded before the Turn
        that first changed it - not from the last commit. That distinction is the
        whole point: work the user did by hand before the Turn survives, and a
        file the agent created is deleted rather than left behind. Uses
        `git restore --source`, which writes only the working tree, so a staged
        change the user prepared themselves is left alone. Files are confined to
        the Project folder; anything else is skipped with a reason. Never throws.
    .PARAMETER Root
        The Project (Workspace) folder.
    .PARAMETER Entries
        The Project's change-set entries.
    .PARAMETER Paths
        The files to undo. Omit to undo every tracked file.
    .OUTPUTS
        System.Collections.Hashtable with restored, removed, skipped, kept and error.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Entries,

        [string[]]$Paths
    )

    $result = @{ restored = @(); removed = @(); skipped = @(); kept = @(); error = $null }

    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root -PathType Container)) { $result.error = 'No project folder.'; return $result }
    try { $rootFull = [System.IO.Path]::GetFullPath($Root) } catch { $result.error = 'Invalid project folder.'; return $result }

    $status = Get-DpGitStatus -Path $rootFull
    if (-not $status.gitAvailable) { $result.error = 'Git is not installed or not on PATH.'; return $result }
    if (-not $status.isRepo) { $result.error = 'This project is not a Git repository, so there is no snapshot to go back to.'; return $result }

    $wanted = $null
    if ($PSBoundParameters.ContainsKey('Paths')) {
        $wanted = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($p in @($Paths)) { if (-not [string]::IsNullOrWhiteSpace($p)) { [void]$wanted.Add(($p -replace '\\', '/')) } }
    }

    $restored = [System.Collections.Generic.List[string]]::new()
    $removed = [System.Collections.Generic.List[string]]::new()
    $skipped = [System.Collections.Generic.List[hashtable]]::new()
    $kept = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($entry in @($Entries)) {
        if (-not $entry) { continue }
        $rel = [string](Get-DpPropertyValue -InputObject $entry -Name @('rel') -Default '')
        if ([string]::IsNullOrWhiteSpace($rel)) { continue }
        if ($wanted -and -not $wanted.Contains($rel)) { $kept.Add($entry); continue }

        $sha = [string](Get-DpPropertyValue -InputObject $entry -Name @('snapshotSha') -Default '')
        if ([string]::IsNullOrWhiteSpace($sha)) {
            $skipped.Add(@{ path = $rel; reason = 'No snapshot was taken for this file.' })
            $kept.Add($entry)
            continue
        }

        $full = Join-Path $rootFull $rel
        $inSnapshot = (Invoke-DpGitCommand -Path $rootFull -Arguments @('cat-file', '-e', "$sha`:$rel")).Ok
        if ($inSnapshot) {
            $restore = Invoke-DpGitCommand -Path $rootFull -Arguments @('restore', '--worktree', '--source', $sha, '--', $rel)
            if ($restore.Ok) { $restored.Add($rel) }
            else {
                $skipped.Add(@{ path = $rel; reason = ($restore.StdErr.Trim()) })
                $kept.Add($entry)
            }
            continue
        }

        # Not in the snapshot: DeskPilot created it, so undoing means removing it.
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            try { Remove-Item -LiteralPath $full -Force -ErrorAction Stop; $removed.Add($rel) }
            catch {
                $skipped.Add(@{ path = $rel; reason = "Could not delete: $($_.Exception.Message)" })
                $kept.Add($entry)
            }
        }
        else { $removed.Add($rel) }
    }

    $result.restored = @($restored)
    $result.removed = @($removed)
    $result.skipped = @($skipped)
    $result.kept = @($kept)
    $result
}
