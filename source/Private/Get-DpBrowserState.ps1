function Get-DpBrowserState {
    <#
    .SYNOPSIS
        The long-lived browser session state, shared across the Host Server and
        the Engine Runspace.
    .DESCRIPTION
        One object for the life of the Engine, deliberately not one per Turn.

        Stop has to reach a live browser while the runspace is mid-Turn, which
        rules out doing it through the runspace, so the state is held here and the
        same reference is injected into the runspace as a global. That much was
        already true. What was not true was the claim that the end of a Turn also
        closes whatever the last Turn left open: the Turn assigned a *fresh*
        hashtable before asking for the close, so the close was handed an object
        with no session in it and the previous session was dropped with no
        remaining reference (B3-4, 2026-09-05).

        A function rather than an inline initialiser because "the same object
        every time" is the property that failed, and a property nothing can
        observe is a property nothing protects.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    if ($null -eq $script:DeskPilot.Engine.BrowserState) {
        $script:DeskPilot.Engine.BrowserState = @{
            session        = $null
            scope          = @()
            granted        = @()
            lastUrl        = ''
            lastNavigation = 0
        }
    }

    $script:DeskPilot.Engine.BrowserState
}
