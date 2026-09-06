function Get-DpChildAssetRoot {
    <#
    .SYNOPSIS
        Resolves the bundled child execution implementation.
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    foreach ($candidate in @((Join-Path $PSScriptRoot 'child'), (Join-Path $PSScriptRoot '..' 'child'))) {
        if (Test-Path -LiteralPath (Join-Path $candidate 'AuthenticatedChannel.cs') -PathType Leaf) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    throw 'The bundled child implementation is missing.'
}
