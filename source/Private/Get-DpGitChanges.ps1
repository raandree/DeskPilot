function Get-DpGitChanges {
    <#
    .SYNOPSIS
        Lists the changed files of a Project with per-file added/deleted counts.
    .DESCRIPTION
        Builds the data the Changes review panel needs: one entry per changed file
        with a plain-language status (added, modified, deleted, renamed, untracked,
        conflicted), the number of added and deleted lines, and a binary flag, plus
        totals over the reported files. Combines `git status --porcelain -z` (which
        is authoritative for which files changed and never quotes a path) with
        `git diff HEAD --numstat` (line counts). Untracked files have no diff
        against HEAD, so their line count is measured from the file itself.

        Both git commands report paths relative to the repository root, which is
        not necessarily the Project folder, so every path is translated to a
        Project-relative one and anything outside the Project is dropped - the
        Project stays the boundary, exactly as for the other file endpoints.

        The reported list is capped while it is built, not afterwards, and only the
        files that are reported are measured, so a Project holding a large
        un-ignored folder cannot make this call expensive on the Host Server's
        single accept thread. Never throws: a missing folder, missing git or
        non-repo are reported in the result fields.
    .PARAMETER Root
        The Project (Workspace) folder.
    .PARAMETER Paths
        Optional filter: only report these files (relative to Root or absolute
        paths inside Root). A path outside Root is ignored.
    .PARAMETER Limit
        The maximum number of files to return. `fileCount` stays exact; the totals
        cover the returned files and `truncated` says the list was capped.
    .OUTPUTS
        System.Collections.Hashtable with gitAvailable, isRepo, branch, files,
        fileCount, totalAdded, totalDeleted, truncated and error.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [string[]]$Paths,

        [int]$Limit = 500
    )

    $result = @{
        gitAvailable = $true
        isRepo       = $false
        branch       = $null
        files        = @()
        fileCount    = 0
        totalAdded   = 0
        totalDeleted = 0
        truncated    = $false
        error        = $null
    }

    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root -PathType Container)) {
        $result.error = 'No project folder.'
        return $result
    }
    try { $rootFull = [System.IO.Path]::GetFullPath($Root) } catch { $result.error = 'Invalid project folder.'; return $result }
    $rootTrim = $rootFull.TrimEnd('\', '/')

    $status = Get-DpGitStatus -Path $rootFull
    $result.gitAvailable = $status.gitAvailable
    if (-not $status.gitAvailable) { $result.error = 'Git is not installed or not on PATH.'; return $result }
    if (-not $status.isRepo) { $result.error = 'This project is not a Git repository.'; return $result }
    $result.isRepo = $true
    $result.branch = $status.branch

    $repoRoot = if ($status.root) { $status.root } else { $rootFull }
    try { $repoRoot = [System.IO.Path]::GetFullPath($repoRoot) } catch { $repoRoot = $rootFull }

    # Optional path filter, normalized to Project-relative forward-slash form.
    $filter = $null
    if ($PSBoundParameters.ContainsKey('Paths')) {
        $filter = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($p in @($Paths)) {
            if ([string]::IsNullOrWhiteSpace($p)) { continue }
            $candidate = if ([System.IO.Path]::IsPathRooted($p)) { $p } else { Join-Path $rootFull $p }
            try { $full = [System.IO.Path]::GetFullPath($candidate) } catch { continue }
            $fullCompare = $full.TrimEnd('\', '/')
            if (-not $fullCompare.StartsWith($rootTrim + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            [void]$filter.Add(($full.Substring($rootTrim.Length).TrimStart('\', '/') -replace '\\', '/'))
        }
    }

    # -uall lists untracked files individually. The collapsed form (-unormal)
    # reports a bare folder, which is not something a diff or a commit can act on.
    $porcelain = Invoke-DpGitCommand -Path $rootFull -Arguments @('status', '--porcelain', '-z', '--untracked-files=all')
    if (-not $porcelain.Ok) {
        $result.error = if ($porcelain.StdErr) { $porcelain.StdErr.Trim() } else { 'Could not read the Git status.' }
        return $result
    }

    $entries = [System.Collections.Generic.List[hashtable]]::new()
    $total = 0
    $tokens = @($porcelain.StdOut -split "`0")
    for ($i = 0; $i -lt $tokens.Count; $i++) {
        $token = $tokens[$i]
        if ($token.Length -lt 4) { continue }
        $x = $token[0]
        $y = $token[1]
        $repoRel = $token.Substring(3)
        $from = $null
        # A rename/copy record is followed by its original path as its own token,
        # whether the rename is in the index (X) or the work tree (Y).
        if ($x -eq 'R' -or $x -eq 'C' -or $y -eq 'R' -or $y -eq 'C') {
            if ($i + 1 -lt $tokens.Count) { $from = $tokens[$i + 1]; $i++ }
        }
        if ([string]::IsNullOrWhiteSpace($repoRel)) { continue }

        $rel = ConvertTo-DpProjectRelativePath -RepositoryRoot $repoRoot -ProjectRoot $rootTrim -Path $repoRel
        if ($null -eq $rel) { continue }
        if ($filter -and -not $filter.Contains($rel)) { continue }

        $total++
        if ($entries.Count -ge $Limit) { continue }

        $state = if ($x -eq '?' -and $y -eq '?') { 'untracked' }
        elseif ($x -eq 'U' -or $y -eq 'U' -or ($x -eq 'A' -and $y -eq 'A') -or ($x -eq 'D' -and $y -eq 'D')) { 'conflicted' }
        elseif ($x -eq 'R' -or $x -eq 'C' -or $y -eq 'R' -or $y -eq 'C') { 'renamed' }
        elseif ($x -eq 'A' -or $y -eq 'A') { 'added' }
        elseif ($x -eq 'D' -or $y -eq 'D') { 'deleted' }
        else { 'modified' }

        $entries.Add(@{
                rel       = $rel
                repoRel   = $repoRel
                from      = if ($from) { ConvertTo-DpProjectRelativePath -RepositoryRoot $repoRoot -ProjectRoot $rootTrim -Path $from } else { $null }
                status    = $state
                staged    = ($x -ne ' ' -and $x -ne '?')
                directory = $repoRel.EndsWith('/')
                added     = 0
                deleted   = 0
                binary    = $false
            })
    }

    $result.fileCount = $total
    $result.truncated = ($total -gt $entries.Count)

    # Line counts for tracked changes. --numstat -z emits "<add>\t<del>\t<path>"
    # records; a rename emits an empty path followed by the old and new paths as
    # separate records. A binary file reports "-" for both counts.
    $numstat = Invoke-DpGitCommand -Path $rootFull -Arguments @('diff', 'HEAD', '--numstat', '-z')
    if (-not $numstat.Ok) {
        # An unborn HEAD (a fresh repo with no commit) has nothing to diff against.
        $numstat = Invoke-DpGitCommand -Path $rootFull -Arguments @('diff', '--numstat', '-z')
    }
    $counts = @{}
    if ($numstat.Ok -and $numstat.StdOut) {
        $records = @($numstat.StdOut -split "`0")
        for ($i = 0; $i -lt $records.Count; $i++) {
            $record = $records[$i]
            if ([string]::IsNullOrWhiteSpace($record)) { continue }
            $parts = $record -split "`t"
            if ($parts.Count -lt 3) { continue }
            $path = $parts[2]
            if ([string]::IsNullOrWhiteSpace($path)) {
                # Rename: the next two records are the old and the new path.
                if ($i + 2 -lt $records.Count) { $path = $records[$i + 2]; $i += 2 } else { continue }
            }
            $isBinary = ($parts[0] -eq '-' -or $parts[1] -eq '-')
            $addedCount = 0
            $deletedCount = 0
            if (-not $isBinary) {
                [void][int]::TryParse($parts[0], [ref]$addedCount)
                [void][int]::TryParse($parts[1], [ref]$deletedCount)
            }
            $counts[$path] = @{ added = $addedCount; deleted = $deletedCount; binary = $isBinary }
        }
    }

    foreach ($entry in $entries) {
        if ($counts.ContainsKey($entry.repoRel)) {
            $entry.added = $counts[$entry.repoRel].added
            $entry.deleted = $counts[$entry.repoRel].deleted
            $entry.binary = $counts[$entry.repoRel].binary
        }
        elseif ($entry.status -eq 'untracked' -and -not $entry.directory) {
            $measured = Measure-DpFileLine -Path (Join-Path $repoRoot $entry.repoRel)
            $entry.added = $measured.lines
            $entry.binary = $measured.binary
        }
        $entry.Remove('repoRel')
        $result.totalAdded += $entry.added
        $result.totalDeleted += $entry.deleted
    }

    $result.files = @($entries)
    $result
}
