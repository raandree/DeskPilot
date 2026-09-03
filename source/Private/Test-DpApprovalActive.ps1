function Test-DpApprovalActive {
    <#
    .SYNOPSIS
        Whether per-call approval gates Terminal commands for this Turn.
    .DESCRIPTION
        One predicate, because three places have to agree and a disagreement is
        silent: New-DpTurnParameter decides whether to pass -DisableTerminal,
        Set-DpTerminalTool decides whether to register the gated Tool, and the UI
        reports which of the two the user is getting. If those drifted apart the
        result would be either a terminal nobody gates or no terminal at all.

        All three conditions are necessary. Terminal Permission off means no
        terminal, which is stricter than approval. Your Tools off would strip the
        gated Tool out of the Turn, leaving -DisableTerminal as the only effect -
        so approval stands down instead, because a withdrawn Permission must never
        become the thing that widens access.
    .PARAMETER Settings
        The effective Settings for this Turn, already narrowed by any Scope.
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Settings
    )

    if (-not $Settings.perCallApproval) { return $false }

    $permissions = $Settings.permissions
    if (-not $permissions) { return $false }

    [bool]$permissions.terminal -and [bool]$permissions.userTools
}
