function Remove-DpBrowserOrphan {
    <#
    .SYNOPSIS
        Closes browser processes DeskPilot started and did not close.
    .DESCRIPTION
        The repair half of Get-DpBrowserOrphan, and it only ever acts on what
        that function identified - a process running from the DeskPilot runtime's
        own browser folder. It never matches on a process name, so the user's own
        browser is not reachable from here.

        Each is stopped independently and a failure is reported rather than
        thrown: a process that exited between the scan and the kill is the
        expected outcome, not an error, and one the account cannot stop should
        not prevent the others being cleaned up.
    .PARAMETER RuntimeRoot
        Where the browser runtime is installed. Defaults to the data directory.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([hashtable])]
    param(
        [string]$RuntimeRoot
    )

    $orphans = @(Get-DpBrowserOrphan -RuntimeRoot $RuntimeRoot)
    $closed = 0
    $failed = [System.Collections.Generic.List[string]]::new()

    foreach ($orphan in $orphans) {
        if (-not $PSCmdlet.ShouldProcess("$($orphan.name) ($($orphan.id))", 'Close leftover browser process')) { continue }
        try {
            $process = Get-Process -Id $orphan.id -ErrorAction Stop
            # Re-checked at the moment of the kill. A PID is reused, and this is
            # a whole-tree kill: acting on a scan a moment old could take down an
            # unrelated process and everything it started.
            $current = ''
            try { $current = [string]$process.Path } catch { $current = '' }
            if ($current -ne $orphan.path) {
                $failed.Add("$($orphan.name) ($($orphan.id)): the process changed between the scan and the close, so it was left alone.")
                continue
            }

            $process.Kill($true)
            $null = $process.WaitForExit(5000)
            $closed++
        }
        catch [Microsoft.PowerShell.Commands.ProcessCommandException] {
            # Already gone between the scan and the kill, which is a success.
            $closed++
        }
        catch {
            $failed.Add("$($orphan.name) ($($orphan.id)): $_")
        }
    }

    @{ found = $orphans.Count; closed = $closed; failed = @($failed.ToArray()) }
}
