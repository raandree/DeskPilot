function Resolve-DpWorkspacePath {
    <#
    .SYNOPSIS
        Confines one candidate path to an already-resolved Workspace Folder.
    .DESCRIPTION
        The single confinement test every DeskPilot workspace Tool goes through,
        so search and edit cannot drift apart. It is deliberately two checks:

        - Lexical. The candidate is combined with the root, fully resolved, and
          must sit under the root prefix. Case is ignored on Windows and honoured
          elsewhere, because on Linux two names differing only by case are two
          different files and folding them is a way past the test rather than a
          nicety.
        - Link target. A symlink or junction whose final target leaves the root is
          refused, because the lexical test cannot see through one.

        A candidate that does not exist is kept: it is lexically inside the root
        and links nowhere, so dropping it would silently hide a file git listed a
        moment ago, and reading it will fail on its own terms. Any other failure to
        classify the path refuses it - a candidate that cannot be shown to be
        inside the root is not inside it.
    .PARAMETER Root
        The resolved Workspace Folder from Resolve-DpWorkspaceRoot.
    .PARAMETER Path
        The candidate, relative to the root or absolute inside it.
    .OUTPUTS
        System.String

        The resolved full path, or nothing when the candidate leaves the root.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Path
    )

    $separator = [System.IO.Path]::DirectorySeparatorChar
    $prefix = $Root.TrimEnd('/', '\') + $separator
    $comparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }

    try { $full = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($Root, $Path)) }
    catch { return }
    if (-not $full.StartsWith($prefix, $comparison)) { return }

    try {
        $link = [System.IO.File]::ResolveLinkTarget($full, $true)
        if ($link -and -not ([System.IO.Path]::GetFullPath($link.FullName)).StartsWith($prefix, $comparison)) { return }
    }
    catch [System.IO.FileNotFoundException] { $null = $_ }
    catch [System.IO.DirectoryNotFoundException] { $null = $_ }
    catch { return }

    $full
}
