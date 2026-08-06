function Get-DpBranchList {
    <#
    .SYNOPSIS
        Lists local + remote-only Branches with a merged-into-Default flag.
    .DESCRIPTION
        Builds the data the branch picker needs: the current Branch, the Default
        Branch, whether a remote exists, and an entry per Branch (local and
        remote-only) with a 'merged' flag computed against the Default Branch.
        When -Fetch is set and a remote exists, fetches first so merged status
        reflects the remote (best effort; a fetch failure degrades to a local
        comparison and is reported in 'fetchError'). Never throws.
    .PARAMETER Path
        The repository folder.
    .PARAMETER Fetch
        Fetch from origin before computing merged status.
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
        currentBranch = $null
        defaultBranch = $null
        hasRemote     = $false
        fetched       = $false
        fetchError    = $null
        branches      = @()
        error         = $null
    }

    $status = Get-DpGitStatus -Path $Path
    $result.gitAvailable = $status.gitAvailable
    if (-not $status.gitAvailable -or -not $status.isRepo) { $result.error = $status.error; return $result }

    $result.isRepo = $true
    $result.currentBranch = if ($status.detached) { $null } else { $status.branch }

    $remotes = Invoke-DpGitCommand -Path $Path -Arguments @('remote')
    $result.hasRemote = $remotes.Ok -and -not [string]::IsNullOrWhiteSpace($remotes.StdOut)

    if ($Fetch -and $result.hasRemote) {
        $f = Invoke-DpGitFetch -Path $Path
        $result.fetched = $f.ok
        if (-not $f.ok) { $result.fetchError = $f.error }
    }

    $default = Get-DpDefaultBranch -Path $Path
    $result.defaultBranch = $default

    $localNames = @()
    $localList = Invoke-DpGitCommand -Path $Path -Arguments @('for-each-ref', '--format=%(refname:short)', 'refs/heads')
    if ($localList.Ok) {
        $localNames = @($localList.StdOut -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }

    $remoteNames = @()
    if ($result.hasRemote) {
        # Ask for the FULL ref name: %(refname:short) abbreviates
        # refs/remotes/origin/HEAD to plain 'origin', which then looks like a
        # branch called after the remote itself. Filter on the full name, then
        # shorten it here.
        $remoteList = Invoke-DpGitCommand -Path $Path -Arguments @('for-each-ref', '--format=%(refname)', 'refs/remotes')
        if ($remoteList.Ok) {
            $remoteNames = @(ConvertFrom-DpRemoteRefName -Line ($remoteList.StdOut -split '\r?\n'))
        }
    }

    # Pick a comparison ref that definitely exists: the local Default Branch if
    # present, else its remote-tracking ref (handles a default that exists only
    # on the remote, e.g. right after clone before a local checkout).
    $compareRef = $null
    if ($default) {
        if ($localNames -contains $default) {
            $compareRef = $default
        }
        elseif ($result.hasRemote) {
            $originRef = "origin/$default"
            $verify = Invoke-DpGitCommand -Path $Path -Arguments @('rev-parse', '--verify', '--quiet', $originRef)
            if ($verify.Ok) { $compareRef = $originRef }
        }
    }

    $mergedLocal = @()
    $mergedRemote = @()
    if ($compareRef) {
        $ml = Invoke-DpGitCommand -Path $Path -Arguments @('branch', '--merged', $compareRef, '--format=%(refname:short)')
        if ($ml.Ok) { $mergedLocal = @($ml.StdOut -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
        $mr = Invoke-DpGitCommand -Path $Path -Arguments @('branch', '-r', '--merged', $compareRef, '--format=%(refname)')
        if ($mr.Ok) { $mergedRemote = @(ConvertFrom-DpRemoteRefName -Line ($mr.StdOut -split '\r?\n')) }
    }

    $entries = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($name in $localNames) {
        $entries.Add(@{
                name      = $name
                display   = $name
                isRemote  = $false
                isCurrent = ($name -eq $result.currentBranch)
                isDefault = ([bool]$default -and $name -eq $default)
                hasLocal  = $true
                merged    = if ($compareRef) { [bool]($mergedLocal -contains $name) } else { $null }
            })
    }

    foreach ($rname in $remoteNames) {
        $shortName = $rname
        $slash = $rname.IndexOf('/')
        if ($slash -ge 0) { $shortName = $rname.Substring($slash + 1) }
        if ($localNames -contains $shortName) { continue }
        $entries.Add(@{
                name      = $rname
                display   = $rname
                shortName = $shortName
                isRemote  = $true
                isCurrent = $false
                isDefault = $false
                hasLocal  = $false
                merged    = if ($compareRef) { [bool]($mergedRemote -contains $rname) } else { $null }
            })
    }

    $result.branches = $entries.ToArray()
    $result
}
