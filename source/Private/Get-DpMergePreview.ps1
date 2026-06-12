function Get-DpMergePreview {
    <#
    .SYNOPSIS
        Previews merging a Branch into the Default Branch for the Merge Wizard.
    .DESCRIPTION
        Reports the commits that would arrive on the Default Branch (the delta),
        plus the preconditions a non-expert needs to know: a dirty working tree,
        whether the local Default Branch is behind its remote, whether the source
        is already merged, and whether a fast-forward is possible. Never throws: a
        missing folder, missing git, non-repo, unknown branch, or a same-as-default
        selection are reported in the result fields.
    .PARAMETER Root
        The Project (Workspace) folder.
    .PARAMETER Branch
        The source Branch to merge (a local name like "feature" or a remote ref
        like "origin/feature").
    .PARAMETER Limit
        The maximum number of incoming commits to return (the count is exact).
    .OUTPUTS
        System.Collections.Hashtable.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [string]$Branch,

        [int]$Limit = 100
    )

    $result = @{
        isRepo        = $false
        sourceBranch  = $Branch
        defaultBranch = $null
        currentBranch = $null
        commits       = @()
        commitCount   = 0
        truncated     = $false
        dirty         = $false
        behind        = $false
        behindCount   = 0
        fastForward   = $false
        alreadyMerged = $false
        sameBranch    = $false
        hasRemote     = $false
        error         = $null
    }

    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root -PathType Container)) {
        $result.error = 'No project folder.'
        return $result
    }
    try { $rootFull = [System.IO.Path]::GetFullPath($Root) } catch { $result.error = 'Invalid project folder.'; return $result }

    $status = Get-DpGitStatus -Path $rootFull
    if (-not $status.gitAvailable) { $result.error = 'Git is not installed or not on PATH.'; return $result }
    if (-not $status.isRepo) { $result.error = 'This project is not a Git repository.'; return $result }
    $result.isRepo = $true
    $result.currentBranch = if ($status.detached) { $null } else { $status.branch }

    $default = Get-DpDefaultBranch -Path $rootFull
    if (-not $default) { $result.error = 'Could not determine the default branch (main or master).'; return $result }
    $result.defaultBranch = $default

    if ($Branch -eq $default) {
        $result.sameBranch = $true
        $result.error = "'$Branch' is the default branch; choose a different branch to merge."
        return $result
    }

    $verify = Invoke-DpGitCommand -Path $rootFull -Arguments @('rev-parse', '--verify', '--quiet', "$Branch^{commit}")
    if (-not $verify.Ok) { $result.error = "Unknown branch '$Branch'."; return $result }

    $remotes = Invoke-DpGitCommand -Path $rootFull -Arguments @('remote')
    $result.hasRemote = $remotes.Ok -and -not [string]::IsNullOrWhiteSpace($remotes.StdOut)

    $porcelain = Invoke-DpGitCommand -Path $rootFull -Arguments @('status', '--porcelain')
    $result.dirty = $porcelain.Ok -and -not [string]::IsNullOrWhiteSpace($porcelain.StdOut)

    if ($result.hasRemote) {
        $originRef = "origin/$default"
        $originVerify = Invoke-DpGitCommand -Path $rootFull -Arguments @('rev-parse', '--verify', '--quiet', $originRef)
        if ($originVerify.Ok) {
            $b = Invoke-DpGitCommand -Path $rootFull -Arguments @('rev-list', '--count', "$default..$originRef")
            if ($b.Ok) {
                $n = 0
                if ([int]::TryParse($b.StdOut.Trim(), [ref]$n)) { $result.behindCount = $n; $result.behind = ($n -gt 0) }
            }
        }
    }

    $range = "$default..$Branch"
    $count = Invoke-DpGitCommand -Path $rootFull -Arguments @('rev-list', '--count', $range)
    $total = 0
    if ($count.Ok) { [void][int]::TryParse($count.StdOut.Trim(), [ref]$total) }
    $result.commitCount = $total
    $result.alreadyMerged = ($total -eq 0)

    $ffCheck = Invoke-DpGitCommand -Path $rootFull -Arguments @('merge-base', '--is-ancestor', $default, $Branch)
    $result.fastForward = ($ffCheck.ExitCode -eq 0)

    if ($total -gt 0) {
        $fmt = '%H%x1f%h%x1f%an%x1f%aI%x1f%s'
        $log = Invoke-DpGitCommand -Path $rootFull -Arguments @('log', '-n', [string]$Limit, "--format=$fmt", '-z', $range)
        if ($log.Ok -and $log.StdOut) {
            $commits = [System.Collections.Generic.List[hashtable]]::new()
            foreach ($chunk in ($log.StdOut -split "`0")) {
                if ([string]::IsNullOrWhiteSpace($chunk)) { continue }
                $f = $chunk -split "`u{001f}"
                if ($f.Count -ge 5) {
                    $commits.Add(@{ sha = $f[0]; shortSha = $f[1]; author = $f[2]; date = $f[3]; subject = $f[4] })
                }
            }
            $result.commits = $commits.ToArray()
        }
        $result.truncated = ($total -gt $Limit)
    }

    $result
}
