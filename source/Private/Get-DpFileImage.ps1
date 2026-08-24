function Get-DpFileImage {
    <#
    .SYNOPSIS
        Reads an image file for the previewers, as raw bytes plus its media type.
    .DESCRIPTION
        Resolves Path (relative to Root or absolute) and confines it to Root the
        same way Get-DpFileContent and Get-DpGitDiff do, then returns the bytes of
        a raster image together with the type to serve it as. The type is decided
        by the file's own signature bytes, never by its extension, so the Host
        Server never hands the browser arbitrary content under a type the browser
        would trust. SVG is deliberately not previewable here: it is script-capable
        markup served from the app's own origin, and being text it already reads
        and diffs as text. A file over MaxBytes is refused rather than truncated -
        half an image is not an image.
    .PARAMETER Root
        The Project folder the read is confined to.
    .PARAMETER Path
        The image to read, relative to Root or an absolute path inside Root.
    .PARAMETER MaxBytes
        The largest image to return. Anything bigger is refused.
    .OUTPUTS
        System.Collections.Hashtable with path, name, bytes, mime, content, code
        and error.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [string]$Path,

        [int]$MaxBytes = 16777216
    )

    $result = @{ path = $null; name = $null; bytes = 0; mime = $null; content = $null; code = $null; error = $null }

    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root -PathType Container)) {
        $result.code = 'no_workspace'
        $result.error = 'No project folder.'
        return $result
    }
    if ([string]::IsNullOrWhiteSpace($Path)) {
        $result.code = 'no_path'
        $result.error = 'No file path.'
        return $result
    }

    try { $rootFull = [System.IO.Path]::GetFullPath($Root) }
    catch { $result.code = 'no_workspace'; $result.error = 'Invalid project folder.'; return $result }

    $candidate = if ([System.IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $rootFull $Path }
    try { $full = [System.IO.Path]::GetFullPath($candidate) }
    catch { $result.code = 'invalid_path'; $result.error = 'Invalid path.'; return $result }

    $rootCompare = $rootFull.TrimEnd('\', '/')
    $inside = $full.TrimEnd('\', '/').StartsWith($rootCompare + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
    if (-not $inside) {
        $result.code = 'outside_workspace'
        $result.error = 'Outside the project folder.'
        return $result
    }

    $result.path = $full
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        $result.code = 'not_found'
        $result.error = 'File not found.'
        return $result
    }

    try {
        $item = Get-Item -LiteralPath $full -ErrorAction Stop
        $result.name = $item.Name
        $result.bytes = [long]$item.Length
        if ($item.Length -gt [Math]::Max(0, $MaxBytes)) {
            $result.code = 'too_large'
            $result.error = 'This image is too large to preview.'
            return $result
        }

        $bytes = [System.IO.File]::ReadAllBytes($full)
        $mime = Get-DpImageMediaType -Bytes $bytes
        if (-not $mime) {
            $result.code = 'not_previewable'
            $result.error = 'This is not an image DeskPilot can preview.'
            return $result
        }
        $result.mime = $mime
        $result.content = $bytes
    }
    catch {
        $result.code = 'read_failed'
        $result.error = "$($_.Exception.Message)"
    }
    $result
}
