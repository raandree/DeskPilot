function Invoke-DpGitMergeUndo {
    <#
    .SYNOPSIS
        Undoes a just-completed merge by resetting the Default Branch to a commit.
    .DESCRIPTION
        Hard-resets the Default Branch to the captured pre-merge commit so a merge
        the Merge Wizard just made is undone. Local only; the caller warns when the
        merge was already pushed. Validates that Sha looks like a commit id and is a
        real commit object before resetting. Never throws.
    .PARAMETER Root
        The Project (Workspace) folder.
    .PARAMETER Sha
        The pre-merge commit id to reset the Default Branch to.
    .OUTPUTS
        System.Collections.Hashtable with ok, defaultBranch and error.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [string]$Sha
    )

    $result = @{ ok = $false; defaultBranch = $null; error = $null }

    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root -PathType Container)) {
        $result.error = 'No project folder.'
        return $result
    }
    try { $rootFull = [System.IO.Path]::GetFullPath($Root) } catch { $result.error = 'Invalid project folder.'; return $result }

    if ($Sha -notmatch '^[0-9a-fA-F]{7,40}$') { $result.error = 'Invalid commit id.'; return $result }

    $status = Get-DpGitStatus -Path $rootFull
    if (-not $status.gitAvailable) { $result.error = 'Git is not installed or not on PATH.'; return $result }
    if (-not $status.isRepo) { $result.error = 'This project is not a Git repository.'; return $result }

    $type = Invoke-DpGitCommand -Path $rootFull -Arguments @('cat-file', '-t', $Sha)
    if (-not $type.Ok -or $type.StdOut.Trim() -ne 'commit') { $result.error = 'That commit was not found in this repository.'; return $result }

    $default = Get-DpDefaultBranch -Path $rootFull
    $result.defaultBranch = $default
    if ($default -and -not $status.detached -and $status.branch -ne $default) {
        $co = Invoke-DpGitCommand -Path $rootFull -Arguments @('checkout', $default)
        if (-not $co.Ok) { $result.error = "Could not switch to '$default': $($co.StdErr.Trim())"; return $result }
    }

    $reset = Invoke-DpGitCommand -Path $rootFull -Arguments @('reset', '--hard', $Sha)
    if (-not $reset.Ok) { $result.error = "Could not undo the merge: $($reset.StdErr.Trim())"; return $result }
    $result.ok = $true
    $result
}
