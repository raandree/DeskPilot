function Get-DpSubagentAssetRoot {
    <#
    .SYNOPSIS
        Resolves the folder holding DeskPilot's bundled Subagent definitions.
    .DESCRIPTION
        The built-in general-purpose Subagent ships with the module so a Turn can
        dispatch one even when every Agent in the user's Agents folder opts out of
        model invocation. The folder sits beside the module in a build and beside
        source/Private in a checkout, the same two places Get-DpChildAssetRoot
        checks for its own bundle.
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $candidates = @(
        (Join-Path -Path $PSScriptRoot -ChildPath 'subagents')
        (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'subagents')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath (Join-Path -Path $candidate -ChildPath 'general-purpose.agent.md') -PathType Leaf) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    throw 'The bundled general-purpose Subagent definition is missing.'
}
