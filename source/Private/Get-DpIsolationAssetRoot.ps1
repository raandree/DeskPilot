function Get-DpIsolationAssetRoot {
    <#
    .SYNOPSIS
        Resolves the bundled, trusted Terminal isolation assets.
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    foreach ($candidate in @((Join-Path $PSScriptRoot 'isolation'), (Join-Path $PSScriptRoot '..' 'isolation'))) {
        if (Test-Path -LiteralPath (Join-Path $candidate 'runtime.json') -PathType Leaf) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    throw 'The bundled Terminal isolation assets are missing. Reinstall DeskPilot.'
}
