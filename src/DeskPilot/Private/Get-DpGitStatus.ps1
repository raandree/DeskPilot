function Get-DpGitStatus {
    <#
    .SYNOPSIS
        Reports the git state of a Project folder for the explorer git bar.
    .DESCRIPTION
        Returns a hashtable describing whether git is installed, whether the
        folder is inside a git work tree, the current branch (or a short commit id
        when detached), and the list of local branches. Designed to never throw:
        a missing folder, missing git, or a non-repo folder are all reported in
        the returned fields rather than as errors.
    .PARAMETER Path
        The Project folder to inspect.
    .OUTPUTS
        System.Collections.Hashtable with gitAvailable, isRepo, branch, detached,
        branches, root and error.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$Path
    )

    $result = @{
        gitAvailable = $true
        isRepo       = $false
        branch       = $null
        detached     = $false
        branches     = @()
        root         = $null
        error        = $null
    }

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Container)) {
        $result.error = 'No project folder.'
        return $result
    }

    $inside = Invoke-DpGitCommand -Path $Path -Arguments @('rev-parse', '--is-inside-work-tree')
    if (-not $inside.Ok) {
        # Distinguish "git missing" from "not a repo": a missing executable yields
        # ExitCode -1; a non-repo yields a non-zero git exit with a fatal message.
        if ($inside.ExitCode -eq -1) {
            $result.gitAvailable = $false
            $result.error = 'Git is not installed or not on PATH.'
        }
        return $result
    }
    if ($inside.StdOut.Trim() -ne 'true') { return $result }

    $result.isRepo = $true

    $top = Invoke-DpGitCommand -Path $Path -Arguments @('rev-parse', '--show-toplevel')
    if ($top.Ok) { $result.root = $top.StdOut.Trim() }

    $current = Invoke-DpGitCommand -Path $Path -Arguments @('branch', '--show-current')
    $branchName = if ($current.Ok) { $current.StdOut.Trim() } else { '' }
    if ($branchName) {
        $result.branch = $branchName
    }
    else {
        # Detached HEAD: show a short commit id instead of a branch name.
        $result.detached = $true
        $short = Invoke-DpGitCommand -Path $Path -Arguments @('rev-parse', '--short', 'HEAD')
        $result.branch = if ($short.Ok) { $short.StdOut.Trim() } else { 'detached' }
    }

    $list = Invoke-DpGitCommand -Path $Path -Arguments @('branch', '--format=%(refname:short)')
    if ($list.Ok) {
        $result.branches = @(
            $list.StdOut -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        )
    }

    $result
}
