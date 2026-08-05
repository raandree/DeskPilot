function ConvertTo-DpProjectRelativePath {
    <#
    .SYNOPSIS
        Translates a repository-relative git path into a Project-relative one.
    .DESCRIPTION
        `git status --porcelain` and `git diff --numstat` always report paths
        relative to the repository root, which is not necessarily the selected
        Project folder - a Project can be a subdirectory of a larger repository.
        This converts such a path into the Project-relative form the rest of
        DeskPilot's file endpoints use, and returns $null when the file lies
        outside the Project so the caller can drop it. The Project remains the
        boundary; nothing outside it is ever reported. Never throws.
    .PARAMETER RepositoryRoot
        The absolute repository root (`git rev-parse --show-toplevel`).
    .PARAMETER ProjectRoot
        The absolute Project folder, without a trailing separator.
    .PARAMETER Path
        The repository-relative path from git.
    .OUTPUTS
        System.String (forward-slash, Project-relative) or $null when outside.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory)]
        [string]$ProjectRoot,

        [Parameter(Mandatory)]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }

    # Git reports a folder with a trailing slash; keep it for the caller but do
    # not let it confuse the boundary comparison.
    $trailing = $Path.EndsWith('/')
    try { $full = [System.IO.Path]::GetFullPath((Join-Path $RepositoryRoot $Path)) } catch { return $null }

    $rootTrim = $ProjectRoot.TrimEnd('\', '/')
    $fullCompare = $full.TrimEnd('\', '/')
    if ($fullCompare.Equals($rootTrim, [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
    if (-not $fullCompare.StartsWith($rootTrim + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) { return $null }

    $rel = $fullCompare.Substring($rootTrim.Length).TrimStart('\', '/') -replace '\\', '/'
    if ($trailing) { $rel += '/' }
    $rel
}
