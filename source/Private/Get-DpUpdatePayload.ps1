function Get-DpUpdatePayload {
    <#
    .SYNOPSIS
        Builds the GET /api/update response from the cached update state.
    .DESCRIPTION
        Returns a client-shaped copy of the Host Server's cached update status
        (populated by the background Gallery check in Update-DpUpdateCheckState),
        so the SPA can show whether a newer DeskPilot is available, drive the
        "Update now" action, and reflect an in-flight check or install. Reads
        $script:DeskPilot; safe to call when no check has run yet.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $state = $script:DeskPilot
    $update = if ($state -and $state.Update) { $state.Update } else { @{} }
    $settings = if ($state) { $state.Settings } else { $null }

    $intervalMinutes = 5
    $includePrereleases = $false
    if ($settings) {
        if ($settings.ContainsKey('updateCheckIntervalMinutes')) { $intervalMinutes = [int]$settings.updateCheckIntervalMinutes }
        if ($settings.ContainsKey('updateIncludePrereleases')) { $includePrereleases = [bool]$settings.updateIncludePrereleases }
    }

    @{
        currentVersion     = [string]$update.currentVersion
        latestStable       = $update.latestStable
        latestPrerelease   = $update.latestPrerelease
        includePrereleases = $includePrereleases
        intervalMinutes    = $intervalMinutes
        updateAvailable    = [bool]$update.updateAvailable
        targetVersion      = $update.targetVersion
        targetIsPrerelease = [bool]$update.targetIsPrerelease
        notice             = $update.notice
        checkedUtc         = $update.checkedUtc
        checking           = [bool]$update.checking
        installing         = [bool]$update.installing
        installResult      = $update.installResult
    }
}
