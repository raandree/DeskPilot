function Save-DpScheduleStore {
    <#
    .SYNOPSIS
        Persists scheduled work atomically.
    .DESCRIPTION
        Writes schedules.json through a temp file plus a forced move, like every
        other DeskPilot store. The run claim is part of that write on purpose: it
        is what lets a restart tell "this run never finished" from "this run never
        started", so an interrupted job is reported rather than silently repeated.
        Never throws.
    .PARAMETER Store
        The schedule store (schedules, queue, claim).
    .PARAMETER Directory
        The per-user data directory.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Store,

        [Parameter(Mandatory)]
        [string]$Directory
    )

    if (-not $PSCmdlet.ShouldProcess($Directory, 'Save DeskPilot schedules')) { return }

    try {
        if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
            $null = New-Item -ItemType Directory -Path $Directory -Force -ErrorAction Stop
        }
        $path = Join-Path $Directory 'schedules.json'
        $temp = "$path.tmp"
        $payload = @{
            schedules = @($Store.schedules)
            queue     = @($Store.queue)
            claim     = $Store.claim
        }
        ($payload | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $temp -Encoding utf8 -ErrorAction Stop
        Move-Item -LiteralPath $temp -Destination $path -Force -ErrorAction Stop
    }
    catch { $null = $_ }
}
