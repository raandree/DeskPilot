function Get-DpBrowserOrphan {
    <#
    .SYNOPSIS
        Finds browser processes DeskPilot started and did not close.
    .DESCRIPTION
        Stop closes the whole process tree, and the end of a Turn closes any
        session the previous one left open. Neither runs if the Host Server is
        killed, the machine sleeps through a crash, or a supervisor is wedged
        hard enough to ignore its stdin closing - so a visible browser window can
        survive with nothing in the UI accounting for it. That is the state this
        reports.

        The discriminator is the executable path, not the process name. Matching
        on "chrome" would sweep up the user's own browser, which is the single
        worst thing this could do; the browsers under the DeskPilot runtime
        folder exist only because DeskPilot downloaded them there, so a process
        running from that folder is DeskPilot's by construction.

        A process whose path cannot be read is reported as not ours. On a shared
        machine that is ordinary rather than suspicious, and guessing in the
        other direction would mean offering to kill something unidentified.
    .PARAMETER RuntimeRoot
        Where the browser runtime is installed. Defaults to the data directory.
    .OUTPUTS
        System.Collections.Hashtable[]
    #>
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param(
        [string]$RuntimeRoot
    )

    if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) {
        $RuntimeRoot = Join-Path (Get-DpDataDir) 'browser'
    }

    $separator = [System.IO.Path]::DirectorySeparatorChar
    $prefix = (Join-Path $RuntimeRoot 'browsers').TrimEnd('/', '\') + $separator
    $comparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }

    $orphans = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($process in @(Get-DpProcessSnapshot)) {
        $path = [string]$process.path
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        if (-not $path.StartsWith($prefix, $comparison)) { continue }
        $orphans.Add(@{
                id      = [int]$process.id
                name    = [string]$process.name
                path    = $path
                started = $process.started
            })
    }

    $orphans.ToArray()
}
