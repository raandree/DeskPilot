function Get-DpUniqueFilePath {
    <#
    .SYNOPSIS
        Returns a non-colliding absolute path under a directory for a given name.
    .DESCRIPTION
        If no file exists at <Directory>/<Name>, returns that path. Otherwise
        appends " (n)" before the extension ("report (1).pdf", "report (2).pdf",
        ...) until it finds a free slot. The input name is sanitised: path
        separators and Windows-invalid characters are replaced with '_'.
    .PARAMETER Directory
        The target directory.
    .PARAMETER Name
        The desired file name (no directory components).
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Directory,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $invalid = ([System.IO.Path]::GetInvalidFileNameChars() + @('/', '\')) | Sort-Object -Unique
    $safe = $Name
    foreach ($c in $invalid) { $safe = $safe -replace [regex]::Escape([string]$c), '_' }
    if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'upload' }

    $candidate = Join-Path $Directory $safe
    if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }

    $stem = [System.IO.Path]::GetFileNameWithoutExtension($safe)
    $ext = [System.IO.Path]::GetExtension($safe)
    for ($i = 1; $i -lt 1000; $i++) {
        $candidate = Join-Path $Directory ("$stem ($i)$ext")
        if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    throw "Could not find a free filename for '$Name' in '$Directory'."
}
