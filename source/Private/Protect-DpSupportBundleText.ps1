function Protect-DpSupportBundleText {
    <#
    .SYNOPSIS
        Redacts secrets and minimizes absolute paths for a support bundle.
    .DESCRIPTION
        Replaces known DeskPilot roots with purpose-plus-leaf markers, then
        reduces remaining Windows, UNC, and POSIX absolute paths to their leaf.
        Ordinary HTTP(S) URLs are not matched. This is intentionally stricter
        than the local Diagnostics view, where two resolved paths are useful.
    .PARAMETER Text
        Text to make shareable.
    .PARAMETER PathMarker
        Known paths with a diagnostic purpose.
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text,

        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$PathMarker = @()
    )

    $safe = Protect-DpDiagnosticText -Text $Text -MaxLength 500
    $comparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    $markers = @($PathMarker | Where-Object {
            -not [string]::IsNullOrWhiteSpace([string](Get-DpPropertyValue -InputObject $_ -Name @('path') -Default ''))
        } | Sort-Object { ([string](Get-DpPropertyValue -InputObject $_ -Name @('path') -Default '')).Length } -Descending)

    foreach ($marker in $markers) {
        $path = [string](Get-DpPropertyValue -InputObject $marker -Name @('path') -Default '')
        $purpose = [string](Get-DpPropertyValue -InputObject $marker -Name @('purpose') -Default 'path')
        $leaf = Split-Path -Path $path -Leaf
        $replacement = "<$purpose`:$leaf>"
        $safe = $safe.Replace($path, $replacement, $comparison)
        $alternatePath = if ($path.Contains('\')) { $path.Replace('\', '/') } else { $path.Replace('/', '\') }
        $safe = $safe.Replace($alternatePath, $replacement, $comparison)
    }

    $windowsPath = '(?i)(?<![A-Za-z0-9])(?:[A-Z]:[\\/]|\\\\[^\\/\s"''<>|]+[\\/][^\\/\s"''<>|]+[\\/])(?:[^\\/\s"''<>|]+[\\/])*([^\\/\s"''<>|]+)'
    $safe = [regex]::Replace($safe, $windowsPath, {
            param($match)
            "<path:$($match.Groups[1].Value)>"
        })

    $posixPath = '(?<![:/A-Za-z0-9])/(?:[^/\s"''<>]+/)+([^/\s"''<>]+)'
    [regex]::Replace($safe, $posixPath, {
            param($match)
            "<path:$($match.Groups[1].Value)>"
        })
}