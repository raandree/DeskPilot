function Get-DpGitSyncStatus {
    <#
    .SYNOPSIS
        Reports how far a Branch is ahead of / behind the server, for the Sync bar.
    .DESCRIPTION
        Answers the three questions a non-expert has before syncing: is there a
        server to sync with, how many of my commits are not there yet (ahead), how
        many of its commits are not here yet (behind), and is anything uncommitted
        or mid-merge. With -Fetch it refreshes the remote-tracking refs first so
        'behind' is current; a fetch failure degrades to the last known state and
        is reported in fetchError. Never throws.
    .PARAMETER Path
        The repository folder.
    .PARAMETER Fetch
        Fetch from the remote before comparing.
    .OUTPUTS
        System.Collections.Hashtable.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$Path,

        [switch]$Fetch
    )

    $result = @{
        gitAvailable  = $true
        isRepo        = $false
        branch        = $null
        detached      = $false
        hasRemote     = $false
        remoteName    = $null
        upstream      = $null
        hasUpstream   = $false
        ahead         = 0
        behind        = 0
        dirty         = $false
        changeCount   = 0
        inMerge       = $false
        conflictFiles = @()
        fetched       = $false
        fetchError    = $null
        error         = $null
    }

    $status = Get-DpGitStatus -Path $Path
    $result.gitAvailable = $status.gitAvailable
    if (-not $status.gitAvailable) { $result.error = 'Git is not installed or not on PATH.'; return $result }
    if (-not $status.isRepo) { $result.error = $status.error; return $result }

    $result.isRepo = $true
    $result.branch = $status.branch
    $result.detached = $status.detached

    $remotes = Invoke-DpGitCommand -Path $Path -Arguments @('remote')
    $remoteNames = @()
    if ($remotes.Ok) { $remoteNames = @($remotes.StdOut -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    $result.hasRemote = $remoteNames.Count -gt 0
    if ($result.hasRemote) { $result.remoteName = if ($remoteNames -contains 'origin') { 'origin' } else { $remoteNames[0] } }

    $porcelain = Invoke-DpGitCommand -Path $Path -Arguments @('status', '--porcelain')
    if ($porcelain.Ok) {
        $lines = @($porcelain.StdOut -split '\r?\n' | Where-Object { $_ })
        $result.changeCount = $lines.Count
        $result.dirty = $lines.Count -gt 0
    }

    $result.inMerge = (Invoke-DpGitCommand -Path $Path -Arguments @('rev-parse', '--verify', '--quiet', 'MERGE_HEAD')).Ok
    # -z, because core.quotePath would otherwise octal-escape a non-ASCII path and
    # that escaped form would reach the conflict list and the generated prompt.
    $conflicts = Invoke-DpGitCommand -Path $Path -Arguments @('diff', '--name-only', '--diff-filter=U', '-z')
    if ($conflicts.Ok) {
        $result.conflictFiles = @($conflicts.StdOut -split "`0" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }

    if ($Fetch -and $result.hasRemote) {
        $f = Invoke-DpGitFetch -Path $Path
        $result.fetched = $f.ok
        if (-not $f.ok) { $result.fetchError = $f.error }
    }

    if (-not $status.detached) {
        $up = Invoke-DpGitCommand -Path $Path -Arguments @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{upstream}')
        if ($up.Ok -and $up.StdOut.Trim()) {
            $result.upstream = $up.StdOut.Trim()
            $result.hasUpstream = $true
            $counts = Invoke-DpGitCommand -Path $Path -Arguments @('rev-list', '--left-right', '--count', "$($result.upstream)...HEAD")
            if ($counts.Ok) {
                $parts = @($counts.StdOut.Trim() -split '\s+' | Where-Object { $_ })
                if ($parts.Count -ge 2) {
                    $behind = 0; $ahead = 0
                    [void][int]::TryParse($parts[0], [ref]$behind)
                    [void][int]::TryParse($parts[1], [ref]$ahead)
                    $result.behind = $behind
                    $result.ahead = $ahead
                }
            }
        }
        elseif ($result.hasRemote -and $status.branch) {
            # No upstream yet: everything on this branch is unpublished. Count the
            # commits that are not on the remote's default branch so the UI can say
            # "publish N commits" instead of a bare "no upstream".
            $default = Get-DpDefaultBranch -Path $Path
            if ($default) {
                $originRef = "$($result.remoteName)/$default"
                if ((Invoke-DpGitCommand -Path $Path -Arguments @('rev-parse', '--verify', '--quiet', $originRef)).Ok) {
                    $ahead = Invoke-DpGitCommand -Path $Path -Arguments @('rev-list', '--count', "$originRef..HEAD")
                    if ($ahead.Ok) { $n = 0; [void][int]::TryParse($ahead.StdOut.Trim(), [ref]$n); $result.ahead = $n }
                }
            }
        }
    }

    $result
}
