function Test-DpBrowserActive {
    <#
    .SYNOPSIS
        Whether the browser Tool may be offered for this Turn.
    .DESCRIPTION
        One predicate, because three places have to agree and a disagreement
        between them is silent: Set-DpBrowserTool decides whether to register the
        Tool, Diagnostics reports whether automation is available, and the UI
        tells the user which of the two they have.

        All conditions are necessary, and the runtime one is the interesting one.
        A Permission the user switched on does not make a browser appear: without
        Node, the pinned Playwright and its browser build, the Tool would be
        advertised to the Model and then fail on every call for reasons the user
        cannot see from the conversation. Reporting unavailable is the honest
        answer, and Diagnostics is where the fix lives.

        Your Tools off stands the browser down rather than leaving the Permission
        half-honoured, the same way approval stands down for the terminal: a
        withdrawn Permission must never be the thing that widens access.
    .PARAMETER Settings
        The effective Settings for this Turn.
    .PARAMETER Runtime
        A runtime report, when the caller already has one. Probed if omitted.
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Settings,

        [AllowNull()]
        [hashtable]$Runtime
    )

    $permissions = $Settings.permissions
    if (-not $permissions) { return $false }
    if (-not [bool]$permissions.browserAutomation) { return $false }
    if (-not [bool]$permissions.userTools) { return $false }

    if ($null -eq $Runtime) { $Runtime = Get-DpBrowserRuntime }
    [bool]$Runtime.ready
}
