function Get-DpModuleVersionString {
    <#
    .SYNOPSIS
        Composes a module's full version string, including any prerelease label.
    .DESCRIPTION
        A module's [System.Version] (Module.Version) cannot carry a prerelease
        label - the installed '0.2.0-preview0004' surfaces as just '0.2.0'. The
        label is stored separately in the manifest's PrivateData.PSData.Prerelease.
        This pure helper recombines them into the Gallery/SemVer form
        'Major.Minor.Patch-prerelease'.

        Without it the update check compares a preview install as if it were the
        matching stable release: a stable release outranks its own prereleases, so
        a running '0.2.0-preview0004' reported as '0.2.0' is never seen as older
        than a newer '0.2.0-preview0005', and no newer preview is ever offered
        (see Get-DpUpdateStatus).

        The base version and prerelease label are taken as strings so the helper
        stays pure and unit-testable; the caller reads them off the module object.
        When the base version already contains a hyphen (already a full SemVer) or
        no label is supplied, the base version is returned unchanged. A leading
        hyphen on the label is tolerated.
    .PARAMETER Version
        The base version string, for example Module.Version.ToString() ('0.2.0').
    .PARAMETER Prerelease
        The prerelease label, normally without a leading hyphen, for example
        Module.PrivateData.PSData.Prerelease ('preview0004'). Optional.
    .OUTPUTS
        System.String
    .EXAMPLE
        Get-DpModuleVersionString -Version '0.2.0' -Prerelease 'preview0004'

        Returns '0.2.0-preview0004'.
    .EXAMPLE
        Get-DpModuleVersionString -Version '0.3.0'

        Returns '0.3.0' (no label supplied).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Version,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Prerelease
    )

    if ([string]::IsNullOrWhiteSpace($Version)) { return '' }
    $baseVersion = $Version.Trim()
    $label = if ([string]::IsNullOrWhiteSpace($Prerelease)) { '' } else { $Prerelease.Trim() }

    # PrivateData.PSData.Prerelease is stored without the leading hyphen, and the
    # base [System.Version] never carries it. Recombine into the SemVer form only
    # when a label is present and the base is not already a full SemVer string.
    if ($label -and $baseVersion -notmatch '-') {
        return '{0}-{1}' -f $baseVersion, $label.TrimStart('-')
    }

    $baseVersion
}
