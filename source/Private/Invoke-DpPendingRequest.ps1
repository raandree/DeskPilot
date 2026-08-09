function Invoke-DpPendingRequest
{
    <#
    .SYNOPSIS
        Services HTTP requests that arrive while a Turn holds the accept thread.
    .DESCRIPTION
        The Host Server accepts and handles requests inline on a single thread,
        so a long-running Turn (Invoke-DpTurn) would otherwise block every other
        request - including POST /stop - until it finished, making the Stop
        button a no-op. Invoke-DpTurn calls this from its polling loop so any
        connection waiting in the listener backlog is accepted and dispatched
        mid-Turn; the stopTurn handler then flips CancelRequested, which the Turn
        loop observes on its next iteration.

        No-ops when no listener is registered (for example in unit tests). Drains
        only the connections already pending, up to a small cap, so it returns to
        streaming promptly and a burst of connections can never starve the Turn.
        Turn-starting routes are guarded by TurnRunning (409), so this never
        starts a nested Turn.
    .PARAMETER MaxRequests
        The most connections to service in one call before yielding back to the
        Turn loop.
    #>
    [CmdletBinding()]
    param
    (
        [int]$MaxRequests = 16
    )

    $state = $script:DeskPilot
    if (-not $state) { return }
    $listener = $state.Listener
    if (-not $listener) { return }

    # Advance Intercom from inside the Turn loop as well. This is exactly when it
    # matters: an Ask-User question has to reach the phone, the answer has to come
    # back, and /stop has to land - all while this thread is busy streaming.
    # -AllowTurn is deliberately not passed: a Turn is already running.
    try { Update-DpIntercomState } catch { $null = $_ }

    $handled = 0
    while ($handled -lt $MaxRequests -and $listener.Pending())
    {
        $client = $listener.AcceptTcpClient()
        # A concurrent request is small and sent in full by our own frontend, so
        # a short read timeout keeps a half-open socket from stalling the stream.
        Invoke-DpClient -Client $client -ReadTimeoutMs 5000
        $handled++
    }
}
