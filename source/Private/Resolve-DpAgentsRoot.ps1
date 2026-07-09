function Resolve-DpAgentsRoot {
    <#
    .SYNOPSIS
        Resolves the effective Agents folder, adopting the conventional default.
    .DESCRIPTION
        Returns the configured Agents root when Settings has one. When it does
        not, falls back to the conventional '~/.copilot/agents' folder ONLY if that
        folder currently exists - so an Agents folder that appears after startup
        (for example after CopilotAtelier setup creates the '~/.copilot/agents'
        junction) is discovered without a restart, while a machine that has no
        '~/.copilot' at all keeps returning nothing (no phantom path). Never throws.
    .PARAMETER Settings
        The DeskPilot Settings hashtable.
    .PARAMETER HomeDirectory
        The home directory to look under. Defaults to $HOME; overridable for tests.
    .OUTPUTS
        System.String (the resolved Agents root) or $null when none applies.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Settings,

        [string]$HomeDirectory = $HOME
    )

    $configured = $Settings.agentsRoot
    if (-not [string]::IsNullOrWhiteSpace($configured)) { return $configured }

    if ([string]::IsNullOrWhiteSpace($HomeDirectory)) { return $null }

    $candidate = Join-Path $HomeDirectory '.copilot/agents'
    if (Test-Path -LiteralPath $candidate -PathType Container -ErrorAction SilentlyContinue) {
        return $candidate
    }

    return $null
}
