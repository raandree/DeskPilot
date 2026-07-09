function Get-DpUpdateStatus {
    <#
    .SYNOPSIS
        Decides whether a newer DeskPilot is available on the Gallery, honouring
        the stable-first, previews-are-opt-in policy.
    .DESCRIPTION
        A pure decision helper with no network of its own. Given the running
        version and the latest versions the Gallery reports (the newest stable,
        and - when previews are enabled - the newest version including
        prereleases), it returns a status object describing whether an update is
        available and which version to target.

        Policy: the newest stable release is the primary target. A preview is
        offered only when IncludePrereleases is set AND the newest preview is
        strictly newer than both the running version and the newest stable. This
        keeps full releases primary while letting an opted-in user ride previews.

        The target's prerelease-ness is reported so the caller (Invoke-DpSelfUpdate)
        can allow ShellPilot prereleases exactly when DeskPilot is updated to a
        prerelease. Unparseable or missing versions are tolerated: the status
        reports no update rather than throwing, so a caller can stay fail-silent
        when the Gallery is unreachable.

        Comparison is prerelease-aware via [System.Management.Automation.SemanticVersion]
        (a stable release outranks its own prerelease; two prereleases compare by
        label), with a fallback that accepts two- or four-part [version] strings.
    .PARAMETER CurrentVersion
        The running module version, for example from the module manifest.
    .PARAMETER LatestStable
        The newest stable version on the Gallery, or empty/null when unknown.
    .PARAMETER LatestPrerelease
        The newest version on the Gallery when prereleases are allowed (may equal
        the stable one, or be empty/null when unknown or not queried).
    .PARAMETER IncludePrereleases
        Consider previews. When off, only a newer stable release is ever offered.
    .OUTPUTS
        System.Collections.Hashtable
    .EXAMPLE
        Get-DpUpdateStatus -CurrentVersion '0.2.0' -LatestStable '0.3.0'

        Reports an available update targeting the stable 0.3.0.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$CurrentVersion,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$LatestStable,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$LatestPrerelease,

        [switch]$IncludePrereleases
    )

    # Parse a Gallery/manifest version string into a SemanticVersion for
    # prerelease-aware comparison. Try SemVer first (handles '1.2.3-preview0002'),
    # then fall back to [version] (handles a 2- or 4-part '1.2' / '1.2.3.4'),
    # padding to the three parts SemVer requires. Returns $null when unparseable.
    $toSemVer = {
        param([string]$Text)
        if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
        $sem = $null
        if ([System.Management.Automation.SemanticVersion]::TryParse($Text, [ref] $sem)) { return $sem }
        $ver = $null
        if ([System.Version]::TryParse($Text, [ref] $ver)) {
            $minor = if ($ver.Minor -lt 0) { 0 } else { $ver.Minor }
            $patch = if ($ver.Build -lt 0) { 0 } else { $ver.Build }
            return [System.Management.Automation.SemanticVersion]::new($ver.Major, $minor, $patch)
        }
        return $null
    }

    $status = @{
        currentVersion     = $CurrentVersion
        latestStable       = if ([string]::IsNullOrWhiteSpace($LatestStable)) { $null } else { $LatestStable }
        latestPrerelease   = if ([string]::IsNullOrWhiteSpace($LatestPrerelease)) { $null } else { $LatestPrerelease }
        includePrereleases = [bool]$IncludePrereleases
        updateAvailable    = $false
        targetVersion      = $null
        targetIsPrerelease = $false
        notice             = $null
    }

    $current = & $toSemVer $CurrentVersion
    if (-not $current) { return $status }

    $stable = & $toSemVer $LatestStable
    $preview = if ($IncludePrereleases) { & $toSemVer $LatestPrerelease } else { $null }

    $stableNewer = $stable -and ($stable -gt $current)
    # A preview is only a candidate when it beats the running version AND is
    # strictly newer than the newest stable (otherwise the stable is preferred).
    $previewNewer = $preview -and ($preview -gt $current) -and (-not $stable -or $preview -gt $stable)

    if ($IncludePrereleases -and $previewNewer) {
        $status.updateAvailable = $true
        $status.targetVersion = $status.latestPrerelease
        $status.targetIsPrerelease = $true
    }
    elseif ($stableNewer) {
        $status.updateAvailable = $true
        $status.targetVersion = $status.latestStable
        $status.targetIsPrerelease = $false
    }

    if ($status.updateAvailable) {
        $kind = if ($status.targetIsPrerelease) { ' (preview)' } else { '' }
        $status.notice = "DeskPilot $($status.targetVersion)$kind is available (installed: $CurrentVersion)."
    }

    $status
}
