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

        Local execution requires all three conditions. Isolated execution keeps
        approval active whenever Terminal Permission is on, independently of the
        Local approval Setting. Its Turn preflight refuses an unavailable owned
        Tool; a withdrawn User Tools Permission must never restore native host
        execution. Terminal Permission off still means no terminal at all.
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

    $permissions = $Settings.permissions
    if (-not $permissions) { return $false }

    if ($Settings.ContainsKey('terminalExecution') -and $Settings.terminalExecution.mode -eq 'isolated') {
        return [bool]$permissions.terminal
    }

    if (-not $Settings.perCallApproval) { return $false }

    [bool]$permissions.terminal -and [bool]$permissions.userTools
}
