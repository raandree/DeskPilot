function Restore-DpSyncStash {
    <#
    .SYNOPSIS
        Puts autostashed changes back, and says so honestly when it cannot.
    .DESCRIPTION
        Every unwind path in Invoke-DpGitSync has to restore the changes it set
        aside. Reporting a failed `stash pop` as restored is the worst outcome for
        the target user: their work is in `refs/stash`, the working tree looks
        empty, and nothing says where it went. This pops only when something was
        stashed, leaves `stashed` true and sets `stashPopConflict` on failure, and
        returns a sentence the caller can append to its own message.
    .PARAMETER Root
        The repository folder.
    .PARAMETER Result
        The in-progress Invoke-DpGitSync result, updated in place.
    .OUTPUTS
        System.String - a sentence to append to the caller's message, or ''.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [hashtable]$Result
    )

    if (-not $Result.stashed) { return '' }

    $pop = Invoke-DpGitCommand -Path $Root -Arguments @('stash', 'pop')
    if ($pop.Ok) {
        $Result.stashed = $false
        return ''
    }

    $Result.stashPopConflict = $true
    ' Your set-aside changes could not be put back automatically - they are safe in the Git stash (run: git stash list).'
}
