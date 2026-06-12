function Get-DpDirectoryEntries {
    <#
    .SYNOPSIS
        Lists the folders and files directly inside a directory for the explorer.
    .DESCRIPTION
        Returns the immediate children of Path: folders first (sorted), then
        files (sorted), each as a record with name, path, type ('dir' or 'file')
        and, for files, size in bytes. Hidden and system entries are skipped. The
        path must resolve to a directory inside (or equal to) Root - a path that
        escapes Root returns an access error - so the explorer stays scoped to the
        selected Project. Enumeration failures are reported in 'error'.
    .PARAMETER Path
        The directory to list. Defaults to Root when empty.
    .PARAMETER Root
        The Project folder the listing is confined to.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [string]$Path
    )

    $result = @{ path = $null; root = $Root; entries = @(); error = $null }

    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root -PathType Container)) {
        $result.error = 'No project folder.'
        return $result
    }

    $rootFull = [System.IO.Path]::GetFullPath($Root)
    $target = if ([string]::IsNullOrWhiteSpace($Path)) { $rootFull } else { $Path }

    try {
        $full = [System.IO.Path]::GetFullPath($target)
    }
    catch {
        $result.path = $rootFull
        $result.error = 'Invalid path.'
        return $result
    }

    # Confine to the Project root (case-insensitive prefix on a separator boundary).
    $rootCompare = $rootFull.TrimEnd('\', '/')
    $fullCompare = $full.TrimEnd('\', '/')
    $inside = $fullCompare -ieq $rootCompare -or $fullCompare.StartsWith($rootCompare + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
    if (-not $inside) {
        $result.path = $rootFull
        $result.error = 'Outside the project folder.'
        return $result
    }

    $result.path = $full
    if (-not (Test-Path -LiteralPath $full -PathType Container)) {
        $result.error = 'Folder not found.'
        return $result
    }

    try {
        $children = Get-ChildItem -LiteralPath $full -Force:$false -ErrorAction Stop |
            Where-Object { -not ($_.Attributes -band ([System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System)) }
        $dirs = @($children | Where-Object { $_.PSIsContainer } | Sort-Object Name | ForEach-Object {
                @{ name = $_.Name; path = $_.FullName; type = 'dir' }
            })
        $files = @($children | Where-Object { -not $_.PSIsContainer } | Sort-Object Name | ForEach-Object {
                @{ name = $_.Name; path = $_.FullName; type = 'file'; bytes = [long]$_.Length }
            })
        $result.entries = @($dirs + $files)
    }
    catch {
        $result.error = "$($_.Exception.Message)"
    }
    $result
}
