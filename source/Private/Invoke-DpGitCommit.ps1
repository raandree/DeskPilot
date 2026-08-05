function Invoke-DpGitCommit {
    <#
    .SYNOPSIS
        Stages and commits changes so a Turn's work can be kept and pushed.
    .DESCRIPTION
        The "Keep" half of the Changes review: stages either the whole working tree
        or only the given files (each confined to Root) and creates a commit. A
        commit is what makes a change durable and pushable, so the Branch Wizard's
        Sync action depends on it. Refuses to run mid-merge, refuses an empty
        message, and reports "nothing to commit" as a distinct, non-error outcome.
        Never throws.
    .PARAMETER Root
        The Project (Workspace) folder every path is confined to.
    .PARAMETER Message
        The commit message.
    .PARAMETER Paths
        Optional: only stage and commit these files. Omit to commit everything.
    .OUTPUTS
        System.Collections.Hashtable with committed, sha, shortSha, summary,
        nothingToCommit and error.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [string]$Message,

        [string[]]$Paths
    )

    $result = @{ committed = $false; sha = $null; shortSha = $null; summary = $null; nothingToCommit = $false; skipped = @(); error = $null }

    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root -PathType Container)) { $result.error = 'No project folder.'; return $result }
    try { $rootFull = [System.IO.Path]::GetFullPath($Root) } catch { $result.error = 'Invalid project folder.'; return $result }
    $rootTrim = $rootFull.TrimEnd('\', '/')

    $text = if ($null -eq $Message) { '' } else { $Message.Trim() }
    if ([string]::IsNullOrWhiteSpace($text)) { $result.error = 'A commit message is required.'; return $result }
    if ($text.Length -gt 5000) { $text = $text.Substring(0, 5000) }

    $status = Get-DpGitStatus -Path $rootFull
    if (-not $status.gitAvailable) { $result.error = 'Git is not installed or not on PATH.'; return $result }
    if (-not $status.isRepo) { $result.error = 'This project is not a Git repository.'; return $result }

    if ((Invoke-DpGitCommand -Path $rootFull -Arguments @('rev-parse', '--verify', '--quiet', 'MERGE_HEAD')).Ok) {
        $result.error = 'A merge is in progress. Finish or abort it before committing.'
        return $result
    }

    $skipped = [System.Collections.Generic.List[hashtable]]::new()
    if ($PSBoundParameters.ContainsKey('Paths') -and @($Paths).Count -gt 0) {
        $rels = [System.Collections.Generic.List[string]]::new()
        foreach ($p in @($Paths)) {
            if ([string]::IsNullOrWhiteSpace($p)) { continue }
            $candidate = if ([System.IO.Path]::IsPathRooted($p)) { $p } else { Join-Path $rootFull $p }
            try { $full = [System.IO.Path]::GetFullPath($candidate) } catch { $skipped.Add(@{ path = $p; reason = 'Invalid path.' }); continue }
            $fullCompare = $full.TrimEnd('\', '/')
            if (-not $fullCompare.StartsWith($rootTrim + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
                $skipped.Add(@{ path = $p; reason = 'Outside the project folder.' })
                continue
            }
            $rels.Add(($full.Substring($rootTrim.Length).TrimStart('\', '/') -replace '\\', '/'))
        }
        $result.skipped = @($skipped)
        if ($rels.Count -eq 0) { $result.error = 'None of those files are inside the project folder.'; return $result }
        $add = Invoke-DpGitCommand -Path $rootFull -Arguments (@('add', '--') + $rels.ToArray())
        if (-not $add.Ok) { $result.error = "Could not stage the files: $($add.StdErr.Trim())"; return $result }
    }
    else {
        $add = Invoke-DpGitCommand -Path $rootFull -Arguments @('add', '-A')
        if (-not $add.Ok) { $result.error = "Could not stage the files: $($add.StdErr.Trim())"; return $result }
    }

    $staged = Invoke-DpGitCommand -Path $rootFull -Arguments @('diff', '--cached', '--name-only')
    if ($staged.Ok -and [string]::IsNullOrWhiteSpace($staged.StdOut)) {
        $result.nothingToCommit = $true
        return $result
    }

    $commit = Invoke-DpGitCommand -Path $rootFull -Arguments @('commit', '-m', $text)
    if (-not $commit.Ok) {
        $combined = (($commit.StdErr, $commit.StdOut) -join "`n").Trim()
        if ($combined -match 'nothing to commit') { $result.nothingToCommit = $true; return $result }
        $result.error = if ($combined) { $combined } else { 'The commit failed.' }
        return $result
    }

    $result.committed = $true
    $head = Invoke-DpGitCommand -Path $rootFull -Arguments @('rev-parse', 'HEAD')
    if ($head.Ok) {
        $result.sha = $head.StdOut.Trim()
        $result.shortSha = $result.sha.Substring(0, [System.Math]::Min(7, $result.sha.Length))
    }
    $result.summary = ($commit.StdOut -split '\r?\n' | Where-Object { $_ } | Select-Object -First 1)
    $result
}
