function Invoke-DpGitRestore {
    <#
    .SYNOPSIS
        Undoes a Turn's file changes inside a Git Project, against the last commit.
    .DESCRIPTION
        For each path (relative to Root or absolute, confined to Root): a tracked
        file that was modified or staged is restored to its state at HEAD
        (`git checkout HEAD -- <file>`); a file git does not track (one the Turn
        newly created) is deleted. A path that is unchanged, outside Root, or
        otherwise not actionable is reported in 'skipped' with a reason. The
        semantics are deliberately "revert to the last commit": DeskPilot has no
        pre-Turn snapshot, so committing before a Turn makes the undo exact. This
        is documented in the UI confirm. Designed never to throw: a missing folder,
        missing git or non-repo are reported in 'error'; per-file failures land in
        'skipped'.
    .PARAMETER Root
        The Project (Workspace) folder every path is confined to.
    .PARAMETER Paths
        The files to undo, relative to Root or absolute paths inside Root.
    .OUTPUTS
        System.Collections.Hashtable with restored, removed, skipped and error.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [string[]]$Paths
    )

    $result = @{ restored = @(); removed = @(); skipped = @(); error = $null }

    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root -PathType Container)) {
        $result.error = 'No project folder.'
        return $result
    }
    try { $rootFull = [System.IO.Path]::GetFullPath($Root) } catch { $result.error = 'Invalid project folder.'; return $result }
    $rootTrim = $rootFull.TrimEnd('\', '/')

    $status = Get-DpGitStatus -Path $rootFull
    if (-not $status.gitAvailable) { $result.error = 'Git is not installed or not on PATH.'; return $result }
    if (-not $status.isRepo) { $result.error = 'This project is not a Git repository.'; return $result }

    $restored = [System.Collections.Generic.List[string]]::new()
    $removed = [System.Collections.Generic.List[string]]::new()
    $skipped = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($path in $Paths) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        $candidate = if ([System.IO.Path]::IsPathRooted($path)) { $path } else { Join-Path $rootFull $path }
        try { $full = [System.IO.Path]::GetFullPath($candidate) } catch { $skipped.Add(@{ path = $path; reason = 'Invalid path.' }); continue }
        $fullCompare = $full.TrimEnd('\', '/')
        $inside = $fullCompare.StartsWith($rootTrim + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
        if (-not $inside) { $skipped.Add(@{ path = $path; reason = 'Outside the project folder.' }); continue }

        $rel = $full.Substring($rootTrim.Length).TrimStart('\', '/') -replace '\\', '/'
        $porcelain = Invoke-DpGitCommand -Path $rootFull -Arguments @('status', '--porcelain', '--', $rel)
        $line = if ($porcelain.Ok) { ($porcelain.StdOut -split '\r?\n' | Where-Object { $_ } | Select-Object -First 1) } else { '' }

        if (-not $line) { $skipped.Add(@{ path = $rel; reason = 'No changes to undo.' }); continue }

        if ($line.StartsWith('??')) {
            # Untracked: a file the Turn created. Remove it.
            try {
                if (Test-Path -LiteralPath $full -PathType Leaf) { Remove-Item -LiteralPath $full -Force -ErrorAction Stop }
                $removed.Add($rel)
            }
            catch { $skipped.Add(@{ path = $rel; reason = "Could not delete: $($_.Exception.Message)" }) }
            continue
        }

        # Tracked + modified/staged: restore to HEAD. Unstage first so a staged
        # change is also reverted, then check out the committed version.
        $null = Invoke-DpGitCommand -Path $rootFull -Arguments @('reset', '-q', 'HEAD', '--', $rel)
        $checkout = Invoke-DpGitCommand -Path $rootFull -Arguments @('checkout', 'HEAD', '--', $rel)
        if ($checkout.Ok) { $restored.Add($rel) }
        else { $skipped.Add(@{ path = $rel; reason = ($checkout.StdErr.Trim()) }) }
    }

    $result.restored = @($restored)
    $result.removed = @($removed)
    $result.skipped = @($skipped)
    $result
}

