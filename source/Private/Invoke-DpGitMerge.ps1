function Invoke-DpGitMerge {
    <#
    .SYNOPSIS
        Merges a Branch into the Default Branch (fast-forward, else a merge commit).
    .DESCRIPTION
        Switches to the Default Branch and merges the source Branch into it with
        git default strategy (fast-forward when possible, otherwise a merge commit).
        Captures the pre-merge commit id so the merge can be undone. Reports one of:
        success, already-merged, conflict (with the conflicted files), blocked (a
        precondition the caller must fix), or error. Never throws.

        Preconditions: a dirty working tree or a Default Branch that is behind its
        remote block the merge unless -Autofix is set, in which case it stashes any
        local changes, fast-forwards the Default Branch from origin, merges, then
        pops the stash on the success path. If the remote fast-forward diverges, it
        restores the stash and returns blocked. If the merge conflicts while changes
        were autostashed, it aborts and restores rather than leaving a fragile mixed
        state, returning blocked so the caller asks the user to commit first.
    .PARAMETER Root
        The Project (Workspace) folder.
    .PARAMETER Branch
        The source Branch to merge.
    .PARAMETER Autofix
        Stash local changes and fast-forward the Default Branch from origin first.
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

        [switch]$Autofix
    )

    $result = @{
        status           = 'error'
        defaultBranch    = $null
        sourceBranch     = $Branch
        switchedFrom     = $null
        preMergeSha      = $null
        mergedSha        = $null
        fastForward      = $false
        conflictFiles    = @()
        stashed          = $false
        pulled           = $false
        stashPopConflict = $false
        reasons          = @()
        error            = $null
    }

    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root -PathType Container)) { $result.error = 'No project folder.'; return $result }
    try { $rootFull = [System.IO.Path]::GetFullPath($Root) } catch { $result.error = 'Invalid project folder.'; return $result }

    $status = Get-DpGitStatus -Path $rootFull
    if (-not $status.gitAvailable) { $result.error = 'Git is not installed or not on PATH.'; return $result }
    if (-not $status.isRepo) { $result.error = 'This project is not a Git repository.'; return $result }

    $default = Get-DpDefaultBranch -Path $rootFull
    if (-not $default) { $result.error = 'Could not determine the default branch (main or master).'; return $result }
    $result.defaultBranch = $default
    if ($Branch -eq $default) { $result.error = "'$Branch' is the default branch; choose a different branch to merge."; return $result }

    $verify = Invoke-DpGitCommand -Path $rootFull -Arguments @('rev-parse', '--verify', '--quiet', "$Branch^{commit}")
    if (-not $verify.Ok) { $result.error = "Unknown branch '$Branch'."; return $result }

    $result.switchedFrom = if ($status.detached) { $null } else { $status.branch }

    $remotes = Invoke-DpGitCommand -Path $rootFull -Arguments @('remote')
    $hasRemote = $remotes.Ok -and -not [string]::IsNullOrWhiteSpace($remotes.StdOut)
    $originRef = "origin/$default"

    $porcelain = Invoke-DpGitCommand -Path $rootFull -Arguments @('status', '--porcelain')
    $dirty = $porcelain.Ok -and -not [string]::IsNullOrWhiteSpace($porcelain.StdOut)

    $behind = $false
    if ($hasRemote) {
        $ov = Invoke-DpGitCommand -Path $rootFull -Arguments @('rev-parse', '--verify', '--quiet', $originRef)
        if ($ov.Ok) {
            $b = Invoke-DpGitCommand -Path $rootFull -Arguments @('rev-list', '--count', "$default..$originRef")
            if ($b.Ok) { $n = 0; if ([int]::TryParse($b.StdOut.Trim(), [ref]$n)) { $behind = ($n -gt 0) } }
        }
    }

    if (-not $Autofix -and ($dirty -or $behind)) {
        $result.status = 'blocked'
        if ($dirty) { $result.reasons += 'dirty' }
        if ($behind) { $result.reasons += 'behind' }
        return $result
    }

    if ($Autofix -and $dirty) {
        $stash = Invoke-DpGitCommand -Path $rootFull -Arguments @('stash', 'push', '-u', '-m', 'DeskPilot merge autostash')
        if (-not $stash.Ok) { $result.error = "Could not stash local changes: $($stash.StdErr.Trim())"; return $result }
        $result.stashed = $true
    }

    if ($result.switchedFrom -ne $default) {
        $co = Invoke-DpGitCommand -Path $rootFull -Arguments @('checkout', $default)
        if (-not $co.Ok) {
            if ($result.stashed) { $null = Invoke-DpGitCommand -Path $rootFull -Arguments @('stash', 'pop') }
            $result.error = "Could not switch to '$default': $($co.StdErr.Trim())"
            return $result
        }
    }

    if ($Autofix -and $hasRemote) {
        $null = Invoke-DpGitFetch -Path $rootFull
        $ov2 = Invoke-DpGitCommand -Path $rootFull -Arguments @('rev-parse', '--verify', '--quiet', $originRef)
        if ($ov2.Ok) {
            $ff = Invoke-DpGitCommand -Path $rootFull -Arguments @('merge', '--ff-only', $originRef)
            if ($ff.Ok) { $result.pulled = $true }
            else {
                if ($result.stashed) { $null = Invoke-DpGitCommand -Path $rootFull -Arguments @('stash', 'pop') }
                $result.status = 'blocked'
                $result.reasons += 'pull-diverged'
                $result.error = "The default branch and its remote have diverged; resolve that before merging. $($ff.StdErr.Trim())"
                return $result
            }
        }
    }

    $head = Invoke-DpGitCommand -Path $rootFull -Arguments @('rev-parse', 'HEAD')
    if ($head.Ok) { $result.preMergeSha = $head.StdOut.Trim() }

    $merge = Invoke-DpGitCommand -Path $rootFull -Arguments @('merge', '--no-edit', $Branch)
    if ($merge.Ok) {
        $newHead = Invoke-DpGitCommand -Path $rootFull -Arguments @('rev-parse', 'HEAD')
        $result.mergedSha = if ($newHead.Ok) { $newHead.StdOut.Trim() } else { $null }
        if ($merge.StdOut -match 'Already up to date') {
            $result.status = 'already-merged'
        }
        else {
            $result.status = 'success'
            $p2 = Invoke-DpGitCommand -Path $rootFull -Arguments @('rev-parse', '--verify', '--quiet', 'HEAD^2')
            $result.fastForward = (-not $p2.Ok)
        }
        if ($result.stashed) {
            $pop = Invoke-DpGitCommand -Path $rootFull -Arguments @('stash', 'pop')
            if (-not $pop.Ok) { $result.stashPopConflict = $true }
            else { $result.stashed = $false }
        }
        return $result
    }

    $conf = Invoke-DpGitCommand -Path $rootFull -Arguments @('diff', '--name-only', '--diff-filter=U')
    $files = @()
    if ($conf.Ok) { $files = @($conf.StdOut -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    if ($files.Count -gt 0) {
        if ($result.stashed) {
            $null = Invoke-DpGitCommand -Path $rootFull -Arguments @('merge', '--abort')
            $null = Invoke-DpGitCommand -Path $rootFull -Arguments @('stash', 'pop')
            $result.status = 'blocked'
            $result.reasons += 'conflict-with-local-changes'
            $result.error = 'This merge has conflicts and you have uncommitted changes. Commit or discard your changes, then merge again to resolve the conflicts with help.'
            return $result
        }
        $result.status = 'conflict'
        $result.conflictFiles = $files
        return $result
    }

    if ($result.stashed) { $null = Invoke-DpGitCommand -Path $rootFull -Arguments @('stash', 'pop') }
    $result.error = "Merge failed: $($merge.StdErr.Trim())"
    $result
}
