function Get-DpDefaultBranch {
    <#
    .SYNOPSIS
        Resolves a repository's Default Branch (the only Merge target).
    .DESCRIPTION
        Returns the name of the Default Branch, resolved in order: the remote
        HEAD (origin/HEAD, set on clone) stripped to its short name; else a local
        'main'; else a local 'master'; else $null when none can be determined.
        Never throws; a missing folder, missing git, or non-repo yields $null.
    .PARAMETER Path
        The repository folder to inspect.
    .OUTPUTS
        System.String (the branch name) or $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Container)) {
        return $null
    }

    # Prefer the remote's default (origin/HEAD), which git sets on clone.
    $head = Invoke-DpGitCommand -Path $Path -Arguments @('symbolic-ref', '--quiet', '--short', 'refs/remotes/origin/HEAD')
    if ($head.Ok) {
        $name = $head.StdOut.Trim()
        if ($name -like 'origin/*') { $name = $name.Substring('origin/'.Length) }
        if ($name) { return $name }
    }

    foreach ($candidate in @('main', 'master')) {
        $ref = Invoke-DpGitCommand -Path $Path -Arguments @('show-ref', '--verify', '--quiet', "refs/heads/$candidate")
        if ($ref.Ok) { return $candidate }
    }

    return $null
}
