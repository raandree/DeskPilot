function Get-DpFileFind {
    <#
    .SYNOPSIS
        Finds files anywhere under a Project root for the composer #file mention.
    .DESCRIPTION
        Recursively enumerates files beneath Root and returns each as a record with
        the file name, its path relative to Root (forward-slashed), the absolute
        path and size in bytes. Hidden and system entries, and a small set of noisy
        folders (.git, node_modules, .vs, bin, obj), are skipped. An optional Query
        filters case-insensitively against the relative path. Results are capped so
        a huge tree cannot flood the UI; the cap being hit is reported in
        'truncated'. The walk is confined to Root: a Root that is missing returns an
        error and no files. Designed never to throw.
    .PARAMETER Root
        The Project folder the search is confined to.
    .PARAMETER Query
        Optional case-insensitive substring matched against the relative path.
    .PARAMETER Limit
        Maximum number of files to return. Defaults to 300.
    .OUTPUTS
        System.Collections.Hashtable with root, files, truncated and error.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [string]$Query,

        [int]$Limit = 300
    )

    $result = @{ root = $Root; files = @(); truncated = $false; error = $null }

    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root -PathType Container)) {
        $result.error = 'No project folder.'
        return $result
    }

    try { $rootFull = [System.IO.Path]::GetFullPath($Root) } catch { $result.error = 'Invalid project folder.'; return $result }
    $rootTrim = $rootFull.TrimEnd('\', '/')
    $skipDirs = @('.git', 'node_modules', '.vs', '.vscode', 'bin', 'obj', '.idea')
    $q = if ([string]::IsNullOrWhiteSpace($Query)) { $null } else { $Query.Trim().ToLowerInvariant() }

    $found = [System.Collections.Generic.List[hashtable]]::new()
    try {
        $all = Get-ChildItem -LiteralPath $rootFull -Recurse -File -Force:$false -ErrorAction SilentlyContinue
        foreach ($file in $all) {
            if ($file.Attributes -band ([System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System)) { continue }
            $rel = $file.FullName.Substring($rootTrim.Length).TrimStart('\', '/') -replace '\\', '/'
            $segments = $rel -split '/'
            $skip = $false
            foreach ($seg in $segments[0..([Math]::Max(0, $segments.Count - 2))]) {
                if ($skipDirs -contains $seg) { $skip = $true; break }
            }
            if ($skip) { continue }
            if ($q -and -not $rel.ToLowerInvariant().Contains($q)) { continue }
            $found.Add(@{ name = $file.Name; rel = $rel; path = $file.FullName; bytes = [long]$file.Length })
            if ($found.Count -ge $Limit) { $result.truncated = $true; break }
        }
    }
    catch {
        $result.error = "$($_.Exception.Message)"
    }

    $result.files = @($found | Sort-Object @{ Expression = { $_.rel } })
    $result
}
