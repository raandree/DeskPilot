function Get-DpProcessSnapshot {
    <#
    .SYNOPSIS
        Lists running processes with the executable path DeskPilot needs.
    .DESCRIPTION
        Its own function so orphan detection has one seam to probe and the tests
        have one thing to replace. `Path` throws for a process this account
        cannot open, which is ordinary on a shared machine, so each is read
        defensively and a process whose path cannot be read is reported with an
        empty one rather than dropped - the caller decides what an unknown path
        means, and for orphan detection it means "not ours".
    .OUTPUTS
        System.Collections.Hashtable[]
    #>
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param()

    $snapshot = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($process in @(Get-Process -ErrorAction SilentlyContinue)) {
        $path = ''
        try { $path = [string]$process.Path } catch { $path = '' }
        $started = $null
        try { $started = $process.StartTime } catch { $started = $null }
        $snapshot.Add(@{ id = $process.Id; name = $process.ProcessName; path = $path; started = $started })
    }

    $snapshot.ToArray()
}
