function Get-DpChangePayload {
    <#
    .SYNOPSIS
        Describes the pending AI change set: what DeskPilot changed, and by how much.
    .DESCRIPTION
        For each tracked file, compares the file as it is now with the snapshot
        taken before DeskPilot first touched it, so the counts and the status
        describe the AI's work rather than "everything different from the last
        commit". A file the user has since reverted by hand reports `unchanged`
        and can be cleared. A file with no snapshot (the Project is not a Git
        repository) is listed but marked not undoable. Never throws.
    .PARAMETER Root
        The Project (Workspace) folder.
    .PARAMETER Entries
        The Project's change-set entries.
    .OUTPUTS
        System.Collections.Hashtable with files, fileCount, totalAdded,
        totalDeleted, undoable and error.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Entries
    )

    $result = @{ files = @(); fileCount = 0; totalAdded = 0; totalDeleted = 0; undoable = $false; error = $null }

    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root -PathType Container)) { $result.error = 'No project folder.'; return $result }
    try { $rootFull = [System.IO.Path]::GetFullPath($Root) } catch { $result.error = 'Invalid project folder.'; return $result }

    $status = Get-DpGitStatus -Path $rootFull
    $result.undoable = ($status.gitAvailable -and $status.isRepo)

    $files = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($entry in @($Entries)) {
        if (-not $entry) { continue }
        $rel = [string](Get-DpPropertyValue -InputObject $entry -Name @('rel') -Default '')
        if ([string]::IsNullOrWhiteSpace($rel)) { continue }
        $sha = [string](Get-DpPropertyValue -InputObject $entry -Name @('snapshotSha') -Default '')

        $exists = Test-Path -LiteralPath (Join-Path $rootFull $rel) -PathType Leaf
        $record = @{
            rel            = $rel
            snapshotSha    = $sha
            conversationId = [string](Get-DpPropertyValue -InputObject $entry -Name @('conversationId') -Default '')
            firstSeenUtc   = [string](Get-DpPropertyValue -InputObject $entry -Name @('firstSeenUtc') -Default '')
            status         = if ($exists) { 'modified' } else { 'deleted' }
            added          = 0
            deleted        = 0
            binary         = $false
            undoable       = ($result.undoable -and -not [string]::IsNullOrWhiteSpace($sha))
            existedBefore  = $true
        }

        if ($record.undoable) {
            $inSnapshot = (Invoke-DpGitCommand -Path $rootFull -Arguments @('cat-file', '-e', "$sha`:$rel")).Ok
            $record.existedBefore = $inSnapshot
            if (-not $inSnapshot) {
                # The agent created it. `git diff <commit> -- <path>` says nothing
                # about a file the commit never had and Git does not track, so the
                # line count comes from the file itself.
                if ($exists) {
                    $record.status = 'added'
                    $measured = Measure-DpFileLine -Path (Join-Path $rootFull $rel)
                    $record.added = $measured.lines
                    $record.binary = $measured.binary
                }
                else { $record.status = 'unchanged' }
            }
            else {
                $counted = $false
                $numstat = Invoke-DpGitCommand -Path $rootFull -Arguments @('diff', '--numstat', '-z', $sha, '--', $rel)
                if ($numstat.Ok -and $numstat.StdOut) {
                    $parts = (@($numstat.StdOut -split "`0") | Where-Object { $_ } | Select-Object -First 1) -split "`t"
                    if ($parts.Count -ge 2) {
                        $counted = $true
                        if ($parts[0] -eq '-' -or $parts[1] -eq '-') { $record.binary = $true }
                        else {
                            $a = 0; $d = 0
                            [void][int]::TryParse($parts[0], [ref]$a)
                            [void][int]::TryParse($parts[1], [ref]$d)
                            $record.added = $a
                            $record.deleted = $d
                        }
                    }
                }
                if (-not $exists) { $record.status = 'deleted' }
                elseif (-not $counted) { $record.status = 'unchanged' }
            }
        }
        elseif (-not $exists) {
            $record.status = 'deleted'
        }

        $result.totalAdded += $record.added
        $result.totalDeleted += $record.deleted
        $files.Add($record)
    }

    $result.files = @($files)
    $result.fileCount = $files.Count
    $result
}
