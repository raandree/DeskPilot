function Invoke-DpMergeApply {
    <#
    .SYNOPSIS
        Applies an approved Merge Plan and completes the merge commit.
    .DESCRIPTION
        Writes each resolved file content (confined to Root, UTF-8 no BOM), stages
        it, applies any binary keep-ours / keep-theirs choices, verifies no
        conflicts remain, then commits the in-progress merge with its prepared
        message. Optionally pops an autostash afterwards. Path-confined and
        never-throwing: a path that escapes Root is refused; remaining conflicts or
        a failed commit are reported in the result.
    .PARAMETER Root
        The Project (Workspace) folder.
    .PARAMETER Resolutions
        The approved resolutions ({ path, content }) to write and stage.
    .PARAMETER BinaryChoices
        Binary resolutions ({ path, choice = ours|theirs }).
    .PARAMETER PopStash
        Pop the most recent stash after committing (restores autostashed changes).
    .PARAMETER CommitMessage
        Optional commit message; defaults to the prepared merge message (--no-edit).
    .OUTPUTS
        System.Collections.Hashtable with ok, mergedSha, remaining, applied,
        stashPopConflict and error.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [AllowEmptyCollection()]
        [object[]]$Resolutions = @(),

        [AllowEmptyCollection()]
        [object[]]$BinaryChoices = @(),

        [switch]$PopStash,

        [string]$CommitMessage
    )

    $result = @{ ok = $false; mergedSha = $null; remaining = @(); applied = @(); stashPopConflict = $false; error = $null }

    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root -PathType Container)) { $result.error = 'No project folder.'; return $result }
    try { $rootFull = [System.IO.Path]::GetFullPath($Root) } catch { $result.error = 'Invalid project folder.'; return $result }
    $rootTrim = $rootFull.TrimEnd('\', '/')

    $status = Get-DpGitStatus -Path $rootFull
    if (-not $status.gitAvailable) { $result.error = 'Git is not installed or not on PATH.'; return $result }
    if (-not $status.isRepo) { $result.error = 'This project is not a Git repository.'; return $result }

    $mergeHead = Invoke-DpGitCommand -Path $rootFull -Arguments @('rev-parse', '--verify', '--quiet', 'MERGE_HEAD')
    if (-not $mergeHead.Ok) { $result.error = 'There is no merge in progress to complete.'; return $result }

    $applied = [System.Collections.Generic.List[string]]::new()
    $utf8 = [System.Text.UTF8Encoding]::new($false)

    foreach ($r in $Resolutions) {
        if (-not $r) { continue }
        $path = if ($r -is [hashtable]) { [string]$r['path'] } else { [string]$r.path }
        $content = if ($r -is [hashtable]) { [string]$r['content'] } else { [string]$r.content }
        if ([string]::IsNullOrWhiteSpace($path)) { continue }

        $candidate = if ([System.IO.Path]::IsPathRooted($path)) { $path } else { Join-Path $rootFull $path }
        try { $full = [System.IO.Path]::GetFullPath($candidate) } catch { $result.error = "Invalid path '$path'."; return $result }
        $inside = $full.TrimEnd('\', '/').StartsWith($rootTrim + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
        if (-not $inside) { $result.error = "Resolution path '$path' is outside the project folder."; return $result }

        $rel = $full.Substring($rootTrim.Length).TrimStart('\', '/') -replace '\\', '/'
        try { [System.IO.File]::WriteAllText($full, $content, $utf8) }
        catch { $result.error = "Could not write '$rel': $($_.Exception.Message)"; return $result }
        $add = Invoke-DpGitCommand -Path $rootFull -Arguments @('add', '--', $rel)
        if (-not $add.Ok) { $result.error = "Could not stage '$rel': $($add.StdErr.Trim())"; return $result }
        $applied.Add($rel)
    }

    foreach ($b in $BinaryChoices) {
        if (-not $b) { continue }
        $path = if ($b -is [hashtable]) { [string]$b['path'] } else { [string]$b.path }
        $choice = if ($b -is [hashtable]) { [string]$b['choice'] } else { [string]$b.choice }
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        if ($choice -ne 'ours' -and $choice -ne 'theirs') { $result.error = "Invalid binary choice '$choice' for '$path' (use ours or theirs)."; return $result }

        $candidate = if ([System.IO.Path]::IsPathRooted($path)) { $path } else { Join-Path $rootFull $path }
        try { $full = [System.IO.Path]::GetFullPath($candidate) } catch { $result.error = "Invalid path '$path'."; return $result }
        $inside = $full.TrimEnd('\', '/').StartsWith($rootTrim + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
        if (-not $inside) { $result.error = "Binary path '$path' is outside the project folder."; return $result }
        $rel = $full.Substring($rootTrim.Length).TrimStart('\', '/') -replace '\\', '/'

        $co = Invoke-DpGitCommand -Path $rootFull -Arguments @('checkout', "--$choice", '--', $rel)
        if (-not $co.Ok) { $result.error = "Could not apply $choice for '$rel': $($co.StdErr.Trim())"; return $result }
        $add = Invoke-DpGitCommand -Path $rootFull -Arguments @('add', '--', $rel)
        if (-not $add.Ok) { $result.error = "Could not stage '$rel': $($add.StdErr.Trim())"; return $result }
        $applied.Add($rel)
    }

    $left = Invoke-DpGitCommand -Path $rootFull -Arguments @('diff', '--name-only', '--diff-filter=U')
    $remaining = @()
    if ($left.Ok) { $remaining = @($left.StdOut -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    if ($remaining.Count -gt 0) {
        $result.remaining = $remaining
        $result.applied = @($applied)
        $result.error = 'Some files still have conflicts; resolve them before completing the merge.'
        return $result
    }

    $commitArgs = if ([string]::IsNullOrWhiteSpace($CommitMessage)) { @('commit', '--no-edit') } else { @('commit', '-m', $CommitMessage) }
    $commit = Invoke-DpGitCommand -Path $rootFull -Arguments $commitArgs
    if (-not $commit.Ok) { $result.applied = @($applied); $result.error = "Could not complete the merge commit: $($commit.StdErr.Trim())"; return $result }

    $newHead = Invoke-DpGitCommand -Path $rootFull -Arguments @('rev-parse', 'HEAD')
    $result.mergedSha = if ($newHead.Ok) { $newHead.StdOut.Trim() } else { $null }
    $result.applied = @($applied)
    $result.ok = $true

    if ($PopStash) {
        $pop = Invoke-DpGitCommand -Path $rootFull -Arguments @('stash', 'pop')
        if (-not $pop.Ok) { $result.stashPopConflict = $true }
    }

    $result
}
