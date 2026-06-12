function Invoke-DpGitMergeAbort {
    <#
    .SYNOPSIS
        Aborts an in-progress merge and optionally restores an autostash.
    .DESCRIPTION
        Runs `git merge --abort`, returning the working tree to its pre-merge
        state. When -PopStash is set (a merge the Merge Wizard started after an
        autostash), it pops the most recent stash afterwards. Never throws.
    .PARAMETER Root
        The Project (Workspace) folder.
    .PARAMETER PopStash
        Pop the most recent stash after aborting (restores autostashed changes).
    .OUTPUTS
        System.Collections.Hashtable with ok, stashPopConflict and error.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [switch]$PopStash
    )

    $result = @{ ok = $false; stashPopConflict = $false; error = $null }

    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root -PathType Container)) {
        $result.error = 'No project folder.'
        return $result
    }
    try { $rootFull = [System.IO.Path]::GetFullPath($Root) } catch { $result.error = 'Invalid project folder.'; return $result }

    $abort = Invoke-DpGitCommand -Path $rootFull -Arguments @('merge', '--abort')
    if (-not $abort.Ok) {
        $result.error = "Could not abort the merge: $($abort.StdErr.Trim())"
        return $result
    }
    $result.ok = $true

    if ($PopStash) {
        $pop = Invoke-DpGitCommand -Path $rootFull -Arguments @('stash', 'pop')
        if (-not $pop.Ok) { $result.stashPopConflict = $true }
    }

    $result
}
