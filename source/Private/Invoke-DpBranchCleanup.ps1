function Invoke-DpBranchCleanup {
    <#
    .SYNOPSIS
        Cleans up a merged Branch: delete it locally, optionally push + delete remote.
    .DESCRIPTION
        After a successful merge, deletes the local Branch (switching to the Default
        Branch first if it is checked out). The networked actions are opt-in and
        each reported separately so a remote failure never undoes the local result:
        -PushDefaultBranch pushes the Default Branch to the remote, and -DeleteRemote
        deletes the Branch on the remote. Uses ambient git credentials. By default a
        safe local delete (`git branch -d`) is used; -Force switches to `-D`. Never
        throws.
    .PARAMETER Root
        The Project (Workspace) folder.
    .PARAMETER Branch
        The merged Branch to clean up (a local name or a remote ref like origin/x).
    .PARAMETER PushDefaultBranch
        Push the Default Branch to the remote.
    .PARAMETER DeleteRemote
        Delete the Branch on the remote.
    .PARAMETER Force
        Use a force local delete (-D) instead of the safe -d.
    .PARAMETER RemoteName
        The remote name (default origin).
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

        [switch]$PushDefaultBranch,

        [switch]$DeleteRemote,

        [switch]$Force,

        [string]$RemoteName = 'origin'
    )

    $result = @{
        defaultBranch = $null
        localDeleted  = $false
        localSkipped  = $false
        localError    = $null
        defaultPushed = $false
        pushError     = $null
        remoteDeleted = $false
        remoteError   = $null
        error         = $null
    }

    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root -PathType Container)) { $result.error = 'No project folder.'; return $result }
    try { $rootFull = [System.IO.Path]::GetFullPath($Root) } catch { $result.error = 'Invalid project folder.'; return $result }

    $status = Get-DpGitStatus -Path $rootFull
    if (-not $status.gitAvailable) { $result.error = 'Git is not installed or not on PATH.'; return $result }
    if (-not $status.isRepo) { $result.error = 'This project is not a Git repository.'; return $result }

    $default = Get-DpDefaultBranch -Path $rootFull
    $result.defaultBranch = $default

    $remotes = Invoke-DpGitCommand -Path $rootFull -Arguments @('remote')
    $remoteNames = @()
    if ($remotes.Ok) { $remoteNames = @($remotes.StdOut -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    $hasRemote = $remoteNames.Count -gt 0

    # Resolve the short branch name (strip a leading "<remote>/").
    $shortName = $Branch
    $slash = $Branch.IndexOf('/')
    if ($slash -ge 0 -and ($remoteNames -contains $Branch.Substring(0, $slash))) {
        $shortName = $Branch.Substring($slash + 1)
    }

    # Local delete (only if a local branch by that name exists).
    $localRef = Invoke-DpGitCommand -Path $rootFull -Arguments @('show-ref', '--verify', '--quiet', "refs/heads/$shortName")
    if ($localRef.Ok) {
        if (-not $status.detached -and $status.branch -eq $shortName -and $default -and $default -ne $shortName) {
            $co = Invoke-DpGitCommand -Path $rootFull -Arguments @('checkout', $default)
            if (-not $co.Ok) { $result.localError = "Could not switch off '$shortName': $($co.StdErr.Trim())" }
        }
        if (-not $result.localError) {
            $flag = if ($Force) { '-D' } else { '-d' }
            $del = Invoke-DpGitCommand -Path $rootFull -Arguments @('branch', $flag, $shortName)
            if ($del.Ok) { $result.localDeleted = $true }
            else { $result.localError = $del.StdErr.Trim() }
        }
    }
    else {
        $result.localSkipped = $true
    }

    if ($PushDefaultBranch) {
        if (-not $hasRemote) { $result.pushError = 'No remote configured.' }
        elseif (-not $default) { $result.pushError = 'Could not determine the default branch.' }
        else {
            $push = Invoke-DpGitCommand -Path $rootFull -Arguments @('push', $RemoteName, $default)
            if ($push.Ok) { $result.defaultPushed = $true }
            else { $result.pushError = $push.StdErr.Trim() }
        }
    }

    if ($DeleteRemote) {
        if (-not $hasRemote) { $result.remoteError = 'No remote configured.' }
        else {
            $rdel = Invoke-DpGitCommand -Path $rootFull -Arguments @('push', $RemoteName, '--delete', $shortName)
            if ($rdel.Ok) { $result.remoteDeleted = $true }
            else { $result.remoteError = $rdel.StdErr.Trim() }
        }
    }

    $result
}
