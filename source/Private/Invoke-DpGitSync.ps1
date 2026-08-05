function Invoke-DpGitSync {
    <#
    .SYNOPSIS
        Pulls from and/or pushes to the server for the Branch Wizard's Sync action.
    .DESCRIPTION
        Implements the three plain-language actions a non-expert needs: 'pull' (get
        the server's commits), 'push' (send mine), and 'sync' (both, in that order,
        because pushing before pulling is what produces the classic rejection). A
        pull fast-forwards when it can and otherwise creates a merge commit; a
        conflict is reported with its files rather than left unexplained. A dirty
        working tree blocks a pull unless -Autostash is set, in which case the
        changes are stashed and restored afterwards. A Branch with no upstream is
        published with `push -u`. Networked git runs with a timeout so the
        single-threaded Host Server can never hang on a stalled remote. Never
        throws: every outcome is reported in 'status' and 'error'.
    .PARAMETER Root
        The Project (Workspace) folder.
    .PARAMETER Action
        pull, push, or sync (pull then push).
    .PARAMETER Autostash
        Stash uncommitted changes before pulling and restore them afterwards.
    .PARAMETER RemoteName
        The remote to use when the Branch has no upstream yet (default origin).
    .OUTPUTS
        System.Collections.Hashtable.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [ValidateSet('pull', 'push', 'sync')]
        [string]$Action = 'sync',

        [switch]$Autostash,

        [string]$RemoteName = 'origin'
    )

    $result = @{
        status           = 'error'
        action           = $Action
        branch           = $null
        upstream         = $null
        published        = $false
        pulled           = $false
        pushed           = $false
        fastForward      = $false
        ahead            = 0
        behind           = 0
        conflictFiles    = @()
        stashed          = $false
        stashPopConflict = $false
        reasons          = @()
        error            = $null
    }

    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root -PathType Container)) { $result.error = 'No project folder.'; return $result }
    try { $rootFull = [System.IO.Path]::GetFullPath($Root) } catch { $result.error = 'Invalid project folder.'; return $result }

    $sync = Get-DpGitSyncStatus -Path $rootFull
    if (-not $sync.gitAvailable) { $result.error = 'Git is not installed or not on PATH.'; return $result }
    if (-not $sync.isRepo) { $result.error = 'This project is not a Git repository.'; return $result }

    $result.branch = $sync.branch
    $result.upstream = $sync.upstream

    if ($sync.detached) {
        $result.status = 'blocked'
        $result.reasons += 'detached'
        $result.error = 'You are not on a branch (detached HEAD). Switch to a branch first.'
        return $result
    }
    if ($sync.inMerge) {
        $result.status = 'blocked'
        $result.reasons += 'in-merge'
        $result.conflictFiles = @($sync.conflictFiles)
        $result.error = 'A merge is still in progress. Finish or abort it first.'
        return $result
    }
    if (-not $sync.hasRemote) {
        $result.status = 'blocked'
        $result.reasons += 'no-remote'
        $result.error = 'This repository has no server (remote) configured, so there is nothing to sync with.'
        return $result
    }

    $remote = if ($sync.remoteName) { $sync.remoteName } else { $RemoteName }

    if ($Action -eq 'pull' -or $Action -eq 'sync') {
        if ($sync.dirty) {
            if (-not $Autostash) {
                $result.status = 'blocked'
                $result.reasons += 'dirty'
                $result.error = 'You have uncommitted changes. Commit them, or let DeskPilot set them aside while it syncs.'
                return $result
            }
            $stash = Invoke-DpGitCommand -Path $rootFull -Arguments @('stash', 'push', '-u', '-m', 'DeskPilot sync autostash')
            if (-not $stash.Ok) { $result.error = "Could not set your changes aside: $($stash.StdErr.Trim())"; return $result }
            $result.stashed = $true
        }

        $fetch = Invoke-DpGitFetch -Path $rootFull
        if (-not $fetch.ok -and -not $sync.hasUpstream) {
            $restore = Restore-DpSyncStash -Root $rootFull -Result $result
            $result.error = "Could not reach the server: $($fetch.error)$restore"
            return $result
        }

        $upstreamRef = if ($sync.hasUpstream) { $sync.upstream } else { "$remote/$($sync.branch)" }
        $upstreamExists = (Invoke-DpGitCommand -Path $rootFull -Arguments @('rev-parse', '--verify', '--quiet', $upstreamRef)).Ok
        if ($upstreamExists) {
            $result.upstream = $upstreamRef
            $ff = Invoke-DpGitCommand -Path $rootFull -Arguments @('merge', '--ff-only', $upstreamRef)
            if ($ff.Ok) {
                $result.pulled = $true
                $result.fastForward = $true
            }
            else {
                $merge = Invoke-DpGitCommand -Path $rootFull -Arguments @('merge', '--no-edit', $upstreamRef)
                if ($merge.Ok) {
                    $result.pulled = $true
                }
                else {
                    $conf = Invoke-DpGitCommand -Path $rootFull -Arguments @('diff', '--name-only', '--diff-filter=U', '-z')
                    $files = @()
                    if ($conf.Ok) { $files = @($conf.StdOut -split "`0" | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
                    if ($files.Count -gt 0 -and $result.stashed) {
                        # Resolving a conflict on top of autostashed work is the
                        # state a non-expert cannot recover from; unwind instead.
                        $null = Invoke-DpGitCommand -Path $rootFull -Arguments @('merge', '--abort')
                        $restore = Restore-DpSyncStash -Root $rootFull -Result $result
                        $result.status = 'blocked'
                        $result.reasons += 'conflict-with-local-changes'
                        $result.error = 'The server''s changes conflict with yours. Commit your changes first, then sync again to resolve the conflict with help.' + $restore
                        return $result
                    }
                    if ($files.Count -gt 0) {
                        $result.status = 'conflict'
                        $result.conflictFiles = $files
                        return $result
                    }
                    $restore = Restore-DpSyncStash -Root $rootFull -Result $result
                    $result.error = "Could not get the server's changes: $($merge.StdErr.Trim())$restore"
                    return $result
                }
            }
        }

        $null = Restore-DpSyncStash -Root $rootFull -Result $result
    }

    if ($Action -eq 'push' -or $Action -eq 'sync') {
        $pushArgs = if ($sync.hasUpstream) { @('push') } else { @('push', '-u', $remote, $sync.branch) }
        $push = Invoke-DpGitCommand -Path $rootFull -Arguments $pushArgs -TimeoutSeconds 120
        if ($push.Ok) {
            $result.pushed = $true
            if (-not $sync.hasUpstream) { $result.published = $true; $result.upstream = "$remote/$($sync.branch)" }
        }
        else {
            $message = if ($push.StdErr) { $push.StdErr.Trim() } else { 'The push was rejected.' }
            if ($message -match 'non-fast-forward|fetch first|behind its remote') {
                $result.status = 'blocked'
                $result.reasons += 'push-rejected'
                $result.error = 'The server has changes you do not have yet. Sync (get them first), then push again.'
            }
            else {
                $result.error = "Could not send your changes: $message"
            }
            return $result
        }
    }

    $after = Get-DpGitSyncStatus -Path $rootFull
    $result.ahead = $after.ahead
    $result.behind = $after.behind
    if ($after.upstream) { $result.upstream = $after.upstream }
    $result.status = 'success'
    $result
}
