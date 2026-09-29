function Invoke-DpGitFetch {
    <#
    .SYNOPSIS
        Best-effort 'git fetch --prune' for Default Branch / merged accuracy.
    .DESCRIPTION
        Fetches updates from the default remote so merged-status comparisons can
        reflect the remote. Never throws: a repo with no remote, an offline host,
        or a credential failure are reported in the returned fields rather than
        raised. Uses the ambient git credential helper / SSH; DeskPilot stores no
        git secrets.
    .PARAMETER Path
        The repository folder.
    .PARAMETER RemoteName
        Fetch only this remote. Without it, git picks its default remote.
    .OUTPUTS
        System.Collections.Hashtable with ok, hasRemote and error.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$Path,

        [string]$RemoteName
    )

    $result = @{ ok = $false; hasRemote = $false; error = $null }

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Container)) {
        $result.error = 'No project folder.'
        return $result
    }

    $remotes = Invoke-DpGitCommand -Path $Path -Arguments @('remote')
    $hasRemote = $remotes.Ok -and -not [string]::IsNullOrWhiteSpace($remotes.StdOut)
    $result.hasRemote = $hasRemote
    if (-not $hasRemote) {
        $result.error = 'No remote configured.'
        return $result
    }

    $fetchArguments = @('fetch', '--prune')
    if (-not [string]::IsNullOrWhiteSpace($RemoteName)) { $fetchArguments += $RemoteName }
    $fetch = Invoke-DpGitCommand -Path $Path -Arguments $fetchArguments -TimeoutSeconds 60
    if ($fetch.Ok) {
        $result.ok = $true
    }
    else {
        $result.error = if ($fetch.StdErr) { $fetch.StdErr.Trim() } else { 'git fetch failed.' }
    }

    $result
}
