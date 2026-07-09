function Update-DpUpdateCheckState {
    <#
    .SYNOPSIS
        Reaps a finished background update check and, when due, starts another.
    .DESCRIPTION
        The engine behind the periodic "is a newer DeskPilot on the Gallery?"
        check. It runs on the Host Server's single accept thread - on idle
        accept-loop iterations, and once with -Force before the loop and from the
        manual POST /api/update/check route - so it never blocks serving and never
        needs its own timer thread.

        Two responsibilities:
          1. Reap. When the background job has finished, read the versions it
             found (the newest stable, and the newest including prereleases when
             previews are enabled), fold them through Get-DpUpdateStatus, and cache
             the resulting status on $script:DeskPilot.Update for GET /api/update.
          2. Trigger. When no job is running and either -Force is set or the
             configured interval has elapsed since the last check, start a fresh
             Start-Job that queries the Gallery off-thread.

        Reads and writes $script:DeskPilot (Version, Settings, Update, UpdateJob,
        LastUpdateCheckUtc). Best-effort and fail-silent: a Gallery or job error
        leaves the last known status in place. The Gallery is queried only through
        this function's background job, never inline on the accept thread.
    .PARAMETER Force
        Start a check now regardless of the interval (used for the first check and
        the manual "Check for updates" button), as long as one is not already
        running.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Updates in-process cached state and background jobs; not a user-facing state change needing ShouldProcess.')]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseUsingScopeModifierInNewRunspaces', '', Justification = 'The Start-Job script block receives its only input through param() plus -ArgumentList, not the parent scope, so a $using: modifier is neither needed nor valid.')]
    param(
        [switch]$Force
    )

    $state = $script:DeskPilot
    if (-not $state) { return }
    if (-not $state.Update) { return }

    $includePrereleases = [bool]$state.Settings.updateIncludePrereleases

    # 1. Reap a finished job.
    if ($state.UpdateJob -and $state.UpdateJob.State -ne 'Running') {
        try {
            $payload = @($state.UpdateJob | Receive-Job -ErrorAction SilentlyContinue) | Select-Object -Last 1
            $stable = if ($payload) { [string]$payload.Stable } else { '' }
            $preview = if ($payload) { [string]$payload.Prerelease } else { '' }
            $status = Get-DpUpdateStatus -CurrentVersion ([string]$state.Version) -LatestStable $stable -LatestPrerelease $preview -IncludePrereleases:$includePrereleases
            $state.Update.currentVersion = [string]$state.Version
            $state.Update.latestStable = $status.latestStable
            $state.Update.latestPrerelease = $status.latestPrerelease
            $state.Update.includePrereleases = $status.includePrereleases
            $state.Update.updateAvailable = $status.updateAvailable
            $state.Update.targetVersion = $status.targetVersion
            $state.Update.targetIsPrerelease = $status.targetIsPrerelease
            $state.Update.notice = $status.notice
            $state.Update.checkedUtc = [DateTime]::UtcNow.ToString('o')
        }
        catch { $null = $_ }
        finally {
            $state.Update.checking = $false
            $state.UpdateJob | Remove-Job -Force -ErrorAction SilentlyContinue
            $state.UpdateJob = $null
        }
    }

    # 2. Trigger a new check when due (and none is running).
    if ($state.UpdateJob) { return }

    $intervalMinutes = 5
    if ($state.Settings -and $state.Settings.ContainsKey('updateCheckIntervalMinutes')) {
        $intervalMinutes = [int]$state.Settings.updateCheckIntervalMinutes
    }
    if ($intervalMinutes -lt 1) { $intervalMinutes = 1 }

    $due = $Force -or (-not $state.LastUpdateCheckUtc) -or
        (([DateTime]::UtcNow - $state.LastUpdateCheckUtc).TotalMinutes -ge $intervalMinutes)
    if (-not $due) { return }

    try {
        $job = Start-Job -ScriptBlock {
            param([bool]$IncludePrerelease)
            $stable = try { (Find-Module -Name DeskPilot -Repository PSGallery -ErrorAction Stop).Version.ToString() } catch { '' }
            $preview = ''
            if ($IncludePrerelease) {
                $preview = try { (Find-Module -Name DeskPilot -Repository PSGallery -AllowPrerelease -ErrorAction Stop).Version.ToString() } catch { '' }
            }
            [pscustomobject]@{ Stable = $stable; Prerelease = $preview }
        } -ArgumentList $includePrereleases
        $state.UpdateJob = $job
        $state.LastUpdateCheckUtc = [DateTime]::UtcNow
        $state.Update.checking = $true
    }
    catch {
        $state.UpdateJob = $null
        $state.Update.checking = $false
    }
}
