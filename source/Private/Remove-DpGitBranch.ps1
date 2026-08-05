function Remove-DpGitBranch {
    <#
    .SYNOPSIS
        Deletes a Branch locally, and optionally on the remote, for the Branch Wizard.
    .DESCRIPTION
        Refuses to delete the Default Branch, and switches to the Default Branch
        first when the Branch to delete is the one checked out. Uses the safe
        `git branch -d` unless -Force is set, so unmerged work is protected by
        default; an unmerged refusal is reported as notMerged = $true so the caller
        can offer an explicit force. The remote delete is a separate, opt-in and
        separately reported action so a remote failure never undoes the local one.
        Never throws.
    .PARAMETER Root
        The Project (Workspace) folder.
    .PARAMETER Name
        The Branch to delete (a local name, or a remote ref like origin/x).
    .PARAMETER Force
        Delete even when the Branch is not fully merged (`git branch -D`).
    .PARAMETER DeleteRemote
        Also delete the Branch on the remote.
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
        [string]$Name,

        [switch]$Force,

        [switch]$DeleteRemote,

        [string]$RemoteName = 'origin'
    )

    $result = @{
        name          = $Name
        deleted       = $false
        notMerged     = $false
        switchedTo    = $null
        remoteDeleted = $false
        remoteError   = $null
        error         = $null
    }

    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root -PathType Container)) { $result.error = 'No project folder.'; return $result }
    try { $rootFull = [System.IO.Path]::GetFullPath($Root) } catch { $result.error = 'Invalid project folder.'; return $result }

    $valid = Test-DpGitBranchName -Name $Name
    if (-not $valid.ok) { $result.error = $valid.error; return $result }

    $status = Get-DpGitStatus -Path $rootFull
    if (-not $status.gitAvailable) { $result.error = 'Git is not installed or not on PATH.'; return $result }
    if (-not $status.isRepo) { $result.error = 'This project is not a Git repository.'; return $result }

    $remotes = Invoke-DpGitCommand -Path $rootFull -Arguments @('remote')
    $remoteNames = @()
    if ($remotes.Ok) { $remoteNames = @($remotes.StdOut -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }

    # Accept a remote ref (origin/feature) and act on the short name. Re-validate:
    # stripping the prefix produces a new token, and only the original was checked.
    $shortName = $valid.name
    $slash = $shortName.IndexOf('/')
    if ($slash -ge 0 -and ($remoteNames -contains $shortName.Substring(0, $slash))) {
        $shortName = $shortName.Substring($slash + 1)
        $shortValid = Test-DpGitBranchName -Name $shortName
        if (-not $shortValid.ok) { $result.error = $shortValid.error; return $result }
        $shortName = $shortValid.name
    }
    $result.name = $shortName

    $default = Get-DpDefaultBranch -Path $rootFull
    if ($default -and $shortName -eq $default) {
        $result.error = "'$shortName' is the default branch and cannot be deleted."
        return $result
    }

    $localExists = (Invoke-DpGitCommand -Path $rootFull -Arguments @('show-ref', '--verify', '--quiet', "refs/heads/$shortName")).Ok
    $wantsLocal = ($valid.name -eq $shortName)

    if ($wantsLocal -and -not $localExists) {
        $result.error = "There is no local branch named '$shortName'."
        return $result
    }

    if ($localExists -and $wantsLocal) {
        if (-not $status.detached -and $status.branch -eq $shortName) {
            if (-not $default) { $result.error = "'$shortName' is the branch you are on, and there is no default branch to switch to first."; return $result }
            $co = Invoke-DpGitCommand -Path $rootFull -Arguments @('checkout', $default)
            if (-not $co.Ok) { $result.error = "Could not switch off '$shortName': $($co.StdErr.Trim())"; return $result }
            $result.switchedTo = $default
        }
        $flag = if ($Force) { '-D' } else { '-d' }
        $del = Invoke-DpGitCommand -Path $rootFull -Arguments @('branch', $flag, $shortName)
        if ($del.Ok) {
            $result.deleted = $true
        }
        else {
            $message = if ($del.StdErr) { $del.StdErr.Trim() } else { 'Could not delete the branch.' }
            if ($message -match 'not fully merged') {
                $result.notMerged = $true
                $result.error = "'$shortName' is not fully merged into the default branch. Deleting it would lose those commits."
            }
            else { $result.error = $message }
            return $result
        }
    }

    if ($DeleteRemote) {
        if ($remoteNames.Count -eq 0) { $result.remoteError = 'No remote configured.' }
        else {
            $rdel = Invoke-DpGitCommand -Path $rootFull -Arguments @('push', $RemoteName, '--delete', '--', $shortName) -TimeoutSeconds 120
            if ($rdel.Ok) { $result.remoteDeleted = $true }
            else { $result.remoteError = if ($rdel.StdErr) { $rdel.StdErr.Trim() } else { 'Could not delete the branch on the server.' } }
        }
    }

    $result
}
