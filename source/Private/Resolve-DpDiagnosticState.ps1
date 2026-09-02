function Resolve-DpDiagnosticState {
    <#
    .SYNOPSIS
        Maps dependency facts to a DeskPilot diagnostic state.
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [bool]$Configured = $true,
        [bool]$Available = $true,
        [bool]$Healthy = $true
    )

    if (-not $Configured) { return 'not configured' }
    if (-not $Available) { return 'unavailable' }
    if (-not $Healthy) { return 'degraded' }
    'healthy'
}