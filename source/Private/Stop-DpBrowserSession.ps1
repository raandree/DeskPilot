function Stop-DpBrowserSession {
    <#
    .SYNOPSIS
        Closes the browser and every process it started.
    .DESCRIPTION
        Stop has to mean stopped. Chromium starts a renderer per site plus GPU
        and utility processes, so killing only the supervisor would leave a
        visible browser window running with no owner - the orphan state the
        prompt names and Diagnostics has to be able to report on.

        Closing stdin first gives the supervisor its ordered shutdown: it closes
        the browser through Playwright, which is the path that also removes the
        ephemeral profile. The kill is the fallback for a supervisor that is
        wedged, and it takes the whole tree.

        Safe to call twice, and on a session that never fully started, because
        the paths that fail during startup all have to be able to clean up.
    .PARAMETER Session
        The session to close.
    .PARAMETER GraceSeconds
        How long the ordered shutdown may take before the tree is killed.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [hashtable]$Session,

        [ValidateRange(1, 60)]
        [int]$GraceSeconds = 10
    )

    if ($null -eq $Session -or -not $Session.process) { return }
    $process = $Session.process

    if (-not $PSCmdlet.ShouldProcess('browser session', 'Close')) { return }

    try {
        if (-not $process.HasExited) {
            try {
                $process.StandardInput.Close()
            }
            catch { $null = $_ }

            if (-not $process.WaitForExit($GraceSeconds * 1000)) {
                # entireProcessTree: the renderers are the point.
                try { $process.Kill($true) } catch { $null = $_ }
                $null = $process.WaitForExit(5000)
            }
        }
    }
    finally {
        $Session.faulted = $true
        try { $process.Dispose() } catch { $null = $_ }
        $Session.process = $null
    }
}
