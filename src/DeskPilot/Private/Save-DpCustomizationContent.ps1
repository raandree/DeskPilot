function Save-DpCustomizationContent {
    <#
    .SYNOPSIS
        Writes edited text back to an existing Customization file.
    .DESCRIPTION
        Validates the path with Resolve-DpCustomizationPath (so only a genuine
        Customization inside a configured root can be written) and requires the
        file to already exist - new files are created with New-DpCustomization, so
        a save can never bring a file into being at an arbitrary location. The text
        is written atomically (a sibling temp file plus Move-Item -Force) as UTF-8
        without a BOM, matching the convention of the .copilot customisation files.
        Throws on any validation failure so the caller can map it to an HTTP 400.
    .PARAMETER Settings
        The DeskPilot Settings hashtable.
    .PARAMETER Category
        The category id (agent, skill, instruction or prompt).
    .PARAMETER Path
        The absolute path of the existing Customization file to overwrite.
    .PARAMETER Text
        The new file contents.
    .PARAMETER MaxBytes
        The largest text payload accepted, as a guard against abuse.
    .OUTPUTS
        System.Collections.Hashtable with ok, path and bytes.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Settings,

        [Parameter(Mandatory)]
        [string]$Category,

        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text,

        [int]$MaxBytes = 4194304
    )

    $resolved = Resolve-DpCustomizationPath -Settings $Settings -Category $Category -Path $Path
    if (-not $resolved.ok) { throw $resolved.error }

    $full = $resolved.full
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw 'File not found.' }

    $encoding = [System.Text.UTF8Encoding]::new($false)
    $bytes = $encoding.GetBytes($Text)
    if ($bytes.Length -gt [Math]::Max(0, $MaxBytes)) {
        throw "The file is too large to save (over $([int]($MaxBytes / 1024)) KiB)."
    }

    $dir = Split-Path -Parent $full
    $temp = Join-Path $dir (".dp-tmp-" + [guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllBytes($temp, $bytes)
        Move-Item -LiteralPath $temp -Destination $full -Force
    }
    finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }

    @{ ok = $true; path = $full; bytes = $bytes.Length }
}
