function Switch-DpGitBranch {
    <#
    .SYNOPSIS
        Switches the Project to a local Branch or to a remote-only Branch.
    .DESCRIPTION
        A local Branch is checked out as it is. A remote-only Branch, named
        '<remote>/<branch>' the way Get-DpBranchList lists it, exists only on the
        server. Switching to it fetches that remote with prune first, so a Branch
        deleted on the server since the list was drawn is refused instead of being
        revived from a stale remote-tracking ref. It then creates a local Branch
        that tracks the remote one and checks it out in a single git step, so a
        refused checkout leaves no Branch behind. When a local Branch with that
        name already exists, that Branch is checked out instead. The fetch is best
        effort: an unreachable server falls back to the copy fetched last time.
        Only names found in the live Branch list reach git. Never throws: every
        failure is reported in 'error' with a stable 'code'.
    .PARAMETER Root
        The Project (Workspace) folder.
    .PARAMETER Name
        A local Branch name, or a remote-only Branch as '<remote>/<branch>'.
    .EXAMPLE
        Switch-DpGitBranch -Root 'C:\Projects\Report' -Name 'origin/draft'

        Creates the local Branch 'draft' that tracks 'origin/draft' and switches to it.
    .OUTPUTS
        System.Collections.Hashtable with switched, branch, created, code and error.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Root,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Name
    )

    $result = @{ switched = $false; branch = $null; created = $false; code = $null; error = $null }

    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root -PathType Container)) {
        $result.code = 'no_workspace'
        $result.error = 'No project folder.'
        return $result
    }
    try {
        $rootFull = [System.IO.Path]::GetFullPath($Root)
    }
    catch {
        $result.code = 'no_workspace'
        $result.error = 'Invalid project folder.'
        return $result
    }

    $status = Get-DpGitStatus -Path $rootFull
    if (-not $status.gitAvailable -or -not $status.isRepo) {
        $result.code = 'not_a_repo'
        $result.error = if ($status.gitAvailable) { 'This project is not a Git repository.' } else { 'Git is not installed or not on PATH.' }
        return $result
    }

    $target = $Name
    $trackedBranch = $null
    if (@($status.branches) -notcontains $Name) {
        $valid = Test-DpGitBranchName -Name $Name
        if (-not $valid.ok) {
            $result.code = 'unknown_branch'
            $result.error = $valid.error
            return $result
        }

        # Not a local Branch, so it has to be '<remote>/<branch>' for a configured
        # remote whose remote-tracking ref this repository already holds.
        $remoteBranch = $valid.name
        $remotes = Invoke-DpGitCommand -Path $rootFull -Arguments @('remote')
        $remoteNames = @()
        if ($remotes.Ok) {
            $remoteNames = @($remotes.StdOut -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        }
        $slash = $remoteBranch.IndexOf('/')
        $remoteName = if ($slash -gt 0) { $remoteBranch.Substring(0, $slash) } else { $null }
        $shortValid = $null
        if ($remoteName -and ($remoteNames -contains $remoteName)) {
            $shortValid = Test-DpGitBranchName -Name $remoteBranch.Substring($slash + 1)
        }
        $trackingRef = "refs/remotes/$remoteBranch"
        $known = $shortValid -and $shortValid.ok -and $shortValid.name -ne 'HEAD' -and
            (Invoke-DpGitCommand -Path $rootFull -Arguments @('show-ref', '--verify', '--quiet', $trackingRef)).Ok
        if (-not $known) {
            $result.code = 'unknown_branch'
            $result.error = "Unknown branch '$remoteBranch'."
            return $result
        }

        $fetch = Invoke-DpGitFetch -Path $rootFull -RemoteName $remoteName
        $stillOnServer = (Invoke-DpGitCommand -Path $rootFull -Arguments @('show-ref', '--verify', '--quiet', $trackingRef)).Ok
        if ($fetch.ok -and -not $stillOnServer) {
            $result.code = 'branch_gone'
            $result.error = "'$($shortValid.name)' no longer exists on the server."
            return $result
        }

        $target = $shortValid.name
        $localExists = (Invoke-DpGitCommand -Path $rootFull -Arguments @('show-ref', '--verify', '--quiet', "refs/heads/$target")).Ok
        if (-not $localExists) { $trackedBranch = $remoteBranch }
    }

    $checkoutArguments = if ($trackedBranch) { @('checkout', '--track', '-b', $target, $trackedBranch) } else { @('checkout', $target) }
    $checkout = Invoke-DpGitCommand -Path $rootFull -Arguments $checkoutArguments
    if (-not $checkout.Ok) {
        $result.code = 'checkout_failed'
        $result.error = if ($checkout.StdErr) { $checkout.StdErr.Trim() } else { 'Could not switch to the branch.' }
        return $result
    }

    $result.switched = $true
    $result.branch = $target
    $result.created = [bool]$trackedBranch
    $result
}
