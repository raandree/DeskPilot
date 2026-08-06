function Get-DpGitDiff {
    <#
    .SYNOPSIS
        Returns the Git diff of a single file inside a Project, against HEAD.
    .DESCRIPTION
        Resolves Path (relative to Root or absolute) and confines it to Root, then
        returns the working-tree diff of that file versus the last commit
        (`git diff HEAD -- <file>`), which captures both staged and unstaged
        changes. A file that git does not track yet (newly created) has no diff
        against HEAD, so it is reported with untracked = $true and its current text
        as 'content' instead. Designed never to throw: a missing folder, missing
        git, non-repo, escaping path or binary file are all reported in the result
        fields. Confinement mirrors Get-DpFileContent: a path that escapes Root is
        refused.
    .PARAMETER Root
        The Project (Workspace) folder the path is confined to.
    .PARAMETER Path
        The file to diff, relative to Root or an absolute path inside Root.
    .PARAMETER BaseSha
        Diff against this commit instead of HEAD. The Changes review passes the
        snapshot taken before DeskPilot first touched the file, so the diff shows
        what the agent did rather than everything since the last commit.
    .OUTPUTS
        System.Collections.Hashtable with rel, isRepo, untracked, diff, content,
        binary and error.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [string]$Path,

        [string]$BaseSha
    )

    $result = @{ rel = $null; isRepo = $false; untracked = $false; diff = ''; content = $null; binary = $false; error = $null }

    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root -PathType Container)) {
        $result.error = 'No project folder.'
        return $result
    }

    try { $rootFull = [System.IO.Path]::GetFullPath($Root) } catch { $result.error = 'Invalid project folder.'; return $result }
    $rootTrim = $rootFull.TrimEnd('\', '/')

    $candidate = if ([System.IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $rootFull $Path }
    try { $full = [System.IO.Path]::GetFullPath($candidate) } catch { $result.error = 'Invalid path.'; return $result }

    $fullCompare = $full.TrimEnd('\', '/')
    $inside = $fullCompare.StartsWith($rootTrim + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
    if (-not $inside) {
        $result.error = 'Outside the project folder.'
        return $result
    }

    $rel = $full.Substring($rootTrim.Length).TrimStart('\', '/') -replace '\\', '/'
    $result.rel = $rel

    $status = Get-DpGitStatus -Path $rootFull
    if (-not $status.gitAvailable) { $result.error = 'Git is not installed or not on PATH.'; return $result }
    if (-not $status.isRepo) { $result.error = 'This project is not a Git repository.'; return $result }
    $result.isRepo = $true

    # Is the file tracked? An untracked file shows up in --porcelain with '??'.
    # With an explicit base that question is moot: the base either has the file or
    # it does not, and `git diff <base>` answers both cases.
    if (-not [string]::IsNullOrWhiteSpace($BaseSha)) {
        $based = Invoke-DpGitCommand -Path $rootFull -Arguments @('diff', $BaseSha, '--', $rel)
        if ($based.Ok) { $result.diff = $based.StdOut; return $result }
        $result.error = if ($based.StdErr) { $based.StdErr.Trim() } else { 'Could not read the changes.' }
        return $result
    }

    $porcelain = Invoke-DpGitCommand -Path $rootFull -Arguments @('status', '--porcelain', '--', $rel)
    $line = if ($porcelain.Ok) { ($porcelain.StdOut -split '\r?\n' | Where-Object { $_ } | Select-Object -First 1) } else { '' }
    if ($line -and $line.StartsWith('??')) {
        $result.untracked = $true
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            try {
                $bytes = [System.IO.File]::ReadAllBytes($full)
                if ($bytes -contains 0) { $result.binary = $true }
                else {
                    $maxPreview = 1MB
                    $slice = if ($bytes.Length -gt $maxPreview) { $bytes[0..($maxPreview - 1)] } else { $bytes }
                    $result.content = [System.Text.Encoding]::UTF8.GetString($slice).TrimStart([char]0xFEFF)
                }
            }
            catch { $result.error = 'Could not read the file.' }
        }
        return $result
    }

    $diff = Invoke-DpGitCommand -Path $rootFull -Arguments @('diff', 'HEAD', '--', $rel)
    if (-not $diff.Ok -and $diff.ExitCode -ne 0 -and $diff.StdErr) {
        # No commits yet, or another git complaint; fall back to a no-HEAD diff.
        $diff = Invoke-DpGitCommand -Path $rootFull -Arguments @('diff', '--', $rel)
    }
    $result.diff = if ($diff.Ok) { $diff.StdOut } else { '' }
    $result
}

