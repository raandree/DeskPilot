function Get-DpCopilotDefaults {
    <#
    .SYNOPSIS
        Derives default Skill, Instruction and Agents roots from ~/.copilot.
    .DESCRIPTION
        Looks for a .copilot folder in the user's home directory and returns the
        sub-folders that exist: skills -> skillRoots, instructions ->
        instructionRoots, prompts -> promptRoots, agents -> agentsRoot. A
        sub-folder that does not exist is omitted (empty array / $null) so a
        machine without .copilot gets no phantom paths. This is how DeskPilot
        seeds sensible defaults from the VS Code Copilot customisation folder.
    .PARAMETER HomeDirectory
        The home directory to look under. Defaults to $HOME; overridable for tests.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$HomeDirectory = $HOME
    )

    $result = @{ skillRoots = @(); instructionRoots = @(); promptRoots = @(); agentsRoot = $null }
    if ([string]::IsNullOrWhiteSpace($HomeDirectory)) { return $result }

    $copilot = Join-Path $HomeDirectory '.copilot'
    if (-not (Test-Path -LiteralPath $copilot -PathType Container)) { return $result }

    $skills = Join-Path $copilot 'skills'
    if (Test-Path -LiteralPath $skills -PathType Container) { $result.skillRoots = @($skills) }

    $instructions = Join-Path $copilot 'instructions'
    if (Test-Path -LiteralPath $instructions -PathType Container) { $result.instructionRoots = @($instructions) }

    $prompts = Join-Path $copilot 'prompts'
    if (Test-Path -LiteralPath $prompts -PathType Container) { $result.promptRoots = @($prompts) }

    $agents = Join-Path $copilot 'agents'
    if (Test-Path -LiteralPath $agents -PathType Container) { $result.agentsRoot = $agents }

    $result
}
