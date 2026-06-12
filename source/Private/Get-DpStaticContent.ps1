function Get-DpStaticContent {
    <#
    .SYNOPSIS
        Reads a static asset from the web root for serving to the SPA.
    .DESCRIPTION
        Resolves a request path under the web root, guards against path traversal,
        and returns the file bytes and content type. An empty path serves
        index.html. Returns a hashtable with Found = $false when the file is
        missing or escapes the web root.
    .PARAMETER WebRoot
        The folder containing the SPA assets.
    .PARAMETER RequestPath
        The request path, for example '/assets/app.js'.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$WebRoot,

        [Parameter(Mandatory)]
        [string]$RequestPath
    )

    $relative = $RequestPath.TrimStart('/')
    if ([string]::IsNullOrWhiteSpace($relative)) { $relative = 'index.html' }

    $rootFull = [System.IO.Path]::GetFullPath($WebRoot)
    $fullPath = [System.IO.Path]::GetFullPath((Join-Path $WebRoot $relative))
    if (-not $fullPath.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        return @{ Found = $false }
    }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        return @{ Found = $false }
    }

    $bytes = [System.IO.File]::ReadAllBytes($fullPath)
    $extension = [System.IO.Path]::GetExtension($fullPath).ToLowerInvariant()
    $contentType = switch ($extension) {
        '.html' { 'text/html; charset=utf-8' }
        '.css' { 'text/css; charset=utf-8' }
        '.js' { 'text/javascript; charset=utf-8' }
        '.mjs' { 'text/javascript; charset=utf-8' }
        '.json' { 'application/json; charset=utf-8' }
        '.svg' { 'image/svg+xml' }
        '.png' { 'image/png' }
        '.jpg' { 'image/jpeg' }
        '.ico' { 'image/x-icon' }
        '.woff2' { 'font/woff2' }
        default { 'application/octet-stream' }
    }

    @{ Found = $true; Bytes = $bytes; ContentType = $contentType }
}
