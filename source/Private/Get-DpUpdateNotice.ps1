function Get-DpUpdateNotice {
    <#
    .SYNOPSIS
        Builds a one-line 'update available' notice by comparing the running
        DeskPilot version to the latest version published on the Gallery.
    .DESCRIPTION
        A pure comparison helper with no network of its own: given the current
        version and the latest published version, it returns a short
        human-readable notice string when the latest is strictly newer, and
        otherwise $null. Missing or unparseable versions also yield $null, so the
        caller can remain fail-silent when the Gallery is unreachable.
    .PARAMETER CurrentVersion
        The running module version, for example from the module manifest.
    .PARAMETER LatestVersion
        The latest version reported by the Gallery, or empty/null when unknown.
    .OUTPUTS
        System.String, or $null when no update notice is warranted.
    .EXAMPLE
        Get-DpUpdateNotice -CurrentVersion '0.2.0' -LatestVersion '0.3.0'

        Returns a notice string because 0.3.0 is newer than 0.2.0.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$CurrentVersion,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$LatestVersion
    )

    $current = $null
    $latest = $null
    if (-not [System.Version]::TryParse($CurrentVersion, [ref] $current)) { return $null }
    if (-not [System.Version]::TryParse($LatestVersion, [ref] $latest)) { return $null }

    if ($latest -gt $current) {
        return "A newer DeskPilot is available on the PowerShell Gallery: $latest (installed: $current). Update with: Update-Module DeskPilot"
    }

    return $null
}
