function Close-DpBrowserSession {
    <#
    .SYNOPSIS
        Closes a browser the current Turn opened, from outside the Engine Runspace.
    .DESCRIPTION
        Stop has to reach the browser while the Turn is still running, and that
        rules out doing it through the runspace: the runspace is executing
        Invoke-Shp at exactly that moment, so opening a [powershell] on it throws
        "a pipeline is already running", and a swallowed exception turns the
        whole call into dead code. The first attempt at this fix did precisely
        that, and a test that grepped for the function's own name reported it
        working.

        So the session state is created **here**, on the Host Server side, and
        the same hashtable reference is injected into the runspace as a global.
        Both sides then hold the same object, the browser's Process handle is an
        ordinary .NET object in one process, and closing it needs no pipeline at
        all - the same reason the approval bridge works across the boundary.

        Safe to call at any time, twice, or on a Turn that never opened a
        browser.
    .PARAMETER State
        The shared browser state, or $null when no Turn has registered one.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [AllowNull()]
        [hashtable]$State
    )

    if ($null -eq $State) { return }

    $session = $State.session
    if ($null -eq $session) { return }

    # Cleared first: Stop and the Turn's finally race by design, and neither
    # should try to close the same session twice.
    $State.session = $null
    try { Stop-DpBrowserSession -Session $session -Confirm:$false }
    catch { $null = $_ }
}
