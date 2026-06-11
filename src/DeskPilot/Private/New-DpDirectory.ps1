function New-DpDirectory {
    <#
    .SYNOPSIS
        Creates a single sub-folder under a parent for the folder-picker UI.
    .DESCRIPTION
        Creates <Parent>/<Name> and returns its resolved path. Name must be a
        single path segment: separators, parent references ('..') and characters
        invalid in a file name are rejected so the new folder cannot escape the
        chosen parent. An existing folder of that name is returned as-is.
    .PARAMETER Parent
        The existing parent directory.
    .PARAMETER Name
        The new folder's name (a single segment).
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Parent,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Parent)) { throw 'A parent folder is required.' }
    if ([string]::IsNullOrWhiteSpace($Name)) { throw 'A folder name is required.' }

    $trimmed = $Name.Trim()
    if ($trimmed -match '[\\/]' -or $trimmed -match '\.\.' -or $trimmed.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) {
        throw "Invalid folder name '$Name'."
    }
    if (-not (Test-Path -LiteralPath $Parent -PathType Container)) {
        throw "Parent folder does not exist: $Parent"
    }

    $full = Join-Path $Parent $trimmed
    if (-not (Test-Path -LiteralPath $full)) {
        New-Item -ItemType Directory -Path $full -Force -ErrorAction Stop | Out-Null
    }
    (Resolve-Path -LiteralPath $full).Path
}
