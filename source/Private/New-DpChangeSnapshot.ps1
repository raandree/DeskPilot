function New-DpChangeSnapshot {
    <#
    .SYNOPSIS
        Captures the Project's current file state so a Turn's edits can be undone.
    .DESCRIPTION
        Records what every file looked like *before* a Turn ran, which is what
        makes "undo what the AI did" a real operation rather than "revert to the
        last commit". The snapshot is an ordinary Git commit object built in a
        throwaway index, so it never touches the user's index, working tree, or
        branch: read HEAD into a temporary index, stage everything (Git's own
        ignore rules apply), write the tree, commit it, and park it under
        `refs/deskpilot/snapshots/<id>` so garbage collection cannot reclaim it.

        A repository with no commit yet is handled - the snapshot simply has no
        parent. A Project that is not a Git repository has no snapshot, and the
        caller reports those changes as not undoable. Never throws.
    .PARAMETER Root
        The Project (Workspace) folder.
    .PARAMETER Id
        A unique id for the snapshot ref (a Turn id).
    .OUTPUTS
        System.Collections.Hashtable with sha, ref, isRepo and error.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [string]$Id
    )

    $result = @{ sha = $null; ref = $null; isRepo = $false; error = $null }

    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root -PathType Container)) { $result.error = 'No project folder.'; return $result }
    try { $rootFull = [System.IO.Path]::GetFullPath($Root) } catch { $result.error = 'Invalid project folder.'; return $result }

    $safeId = ($Id -replace '[^0-9A-Za-z_-]', '')
    if ([string]::IsNullOrWhiteSpace($safeId)) { $result.error = 'Invalid snapshot id.'; return $result }

    $status = Get-DpGitStatus -Path $rootFull
    if (-not $status.gitAvailable -or -not $status.isRepo) { $result.error = 'This project is not a Git repository.'; return $result }
    $result.isRepo = $true

    $indexFile = Join-Path ([System.IO.Path]::GetTempPath()) ("deskpilot-index-$([guid]::NewGuid().ToString('N'))")
    $indexEnv = @{ GIT_INDEX_FILE = $indexFile }
    try {
        $hasHead = (Invoke-DpGitCommand -Path $rootFull -Arguments @('rev-parse', '--verify', '--quiet', 'HEAD')).Ok
        if ($hasHead) {
            $read = Invoke-DpGitCommand -Path $rootFull -Arguments @('read-tree', 'HEAD') -Environment $indexEnv
            if (-not $read.Ok) { $result.error = "Could not read the current commit: $($read.StdErr.Trim())"; return $result }
        }

        $add = Invoke-DpGitCommand -Path $rootFull -Arguments @('add', '-A') -Environment $indexEnv
        if (-not $add.Ok) { $result.error = "Could not capture the current files: $($add.StdErr.Trim())"; return $result }

        $tree = Invoke-DpGitCommand -Path $rootFull -Arguments @('write-tree') -Environment $indexEnv
        if (-not $tree.Ok) { $result.error = "Could not capture the current files: $($tree.StdErr.Trim())"; return $result }
        $treeSha = $tree.StdOut.Trim()

        $commitArgs = @('commit-tree', $treeSha, '-m', 'DeskPilot snapshot before a turn')
        if ($hasHead) {
            $head = Invoke-DpGitCommand -Path $rootFull -Arguments @('rev-parse', 'HEAD')
            if ($head.Ok) { $commitArgs = @('commit-tree', $treeSha, '-p', $head.StdOut.Trim(), '-m', 'DeskPilot snapshot before a turn') }
        }
        $commit = Invoke-DpGitCommand -Path $rootFull -Arguments $commitArgs -Environment $indexEnv
        if (-not $commit.Ok) { $result.error = "Could not record the snapshot: $($commit.StdErr.Trim())"; return $result }
        $sha = $commit.StdOut.Trim()

        $refName = "refs/deskpilot/snapshots/$safeId"
        $update = Invoke-DpGitCommand -Path $rootFull -Arguments @('update-ref', $refName, $sha)
        if (-not $update.Ok) { $result.error = "Could not keep the snapshot: $($update.StdErr.Trim())"; return $result }

        $result.sha = $sha
        $result.ref = $refName
    }
    finally {
        if (Test-Path -LiteralPath $indexFile) { Remove-Item -LiteralPath $indexFile -Force -ErrorAction SilentlyContinue }
    }

    $result
}
