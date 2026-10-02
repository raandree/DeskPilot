function Set-DpSubagentTool {
    <#
    .SYNOPSIS
        Enables or removes the run_subagent Tool for the next Turn.
    .DESCRIPTION
        Called once per Turn, after the Turn's Engine parameters are known,
        because a Subagent inherits them: the Disable* switches and the approval
        control. A registered User Tool outlives the Turn that registered it, so
        removal is as explicit as registration - otherwise a Tool left over from
        an earlier Turn would keep a stale catalog, capability and ledger.
    .PARAMETER Runspace
        The idle Engine Runspace.
    .PARAMETER Enabled
        Whether the next Turn offers run_subagent.
    .PARAMETER Context
        The Turn's Subagent context from New-DpSubagentContext. Required when
        Enabled.
    .OUTPUTS
        System.Boolean - whether run_subagent is registered afterwards.
    #>
    [CmdletBinding()]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Per-Turn Tool registration inside the Engine Runspace, done by the Host Server like the other owned Tools; there is no user to confirm it.')]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Runspaces.Runspace]$Runspace,

        [Parameter(Mandatory)]
        [bool]$Enabled,

        [hashtable]$Context
    )

    if ($Enabled) {
        if ($null -eq $Context) { throw 'A Subagent context is required to register run_subagent.' }
        $description = Get-DpSubagentToolDescription -Catalog @($Context.catalog) -Limit $Context.limits
        return Initialize-DpSubagentTool -Runspace $Runspace -Context $Context -Description $description
    }

    $shell = [powershell]::Create()
    $shell.Runspace = $Runspace
    try {
        # Unregister-ShpTool only warns about a name it does not hold, so this is
        # safe on a runspace that never had the Tool. Get-Module, not Get-Command:
        # a lookup by name could autoload an Engine into a runspace that has none.
        $null = $shell.AddScript(@'
Set-Variable -Name DeskPilotSubagentContext -Scope Global -Value $null
if (Get-Module -Name ShellPilot) {
    Unregister-ShpTool -Name 'run_subagent' -Confirm:$false -WarningAction SilentlyContinue
}
'@)
        $shell.Invoke() | Out-Null
        if ($shell.HadErrors) {
            $firstError = $shell.Streams.Error | Select-Object -First 1
            throw $(if ($firstError) { $firstError.ToString() } else { 'Could not remove run_subagent.' })
        }
    }
    finally {
        $shell.Dispose()
    }

    $false
}
