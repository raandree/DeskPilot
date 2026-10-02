function New-DpSubagentContext {
    <#
    .SYNOPSIS
        Decides whether a Turn offers run_subagent and builds what the Tool needs.
    .DESCRIPTION
        A Subagent is a strict subset of the Turn that dispatches it. This builds
        the parent capability Invoke-ShpSubagent attenuates from: the Turn's own
        Disable* switches and - when broader approval is on - the very
        ToolCallControl object the Turn runs under, so every Tool call the
        Subagent makes reaches the same approval as the Turn's own would.

        The Tool stays off, with a reason, unless every condition holds:
        - the Subagents Permission is on;
        - User Tools is on, because run_subagent is a User Tool and the Engine
          withholds it otherwise;
        - the Engine has the bounded Subagent contract;
        - approval, if any, rides on ToolCallControl. The legacy
          ToolCallApprover has no place in a Subagent's capability, so a
          Subagent would run without it; that is a widening, and it is refused;
        - the catalog allows at least one Subagent.

        The context is Host-built data. Nothing in it comes from the Model.
    .PARAMETER Settings
        The Settings the Turn runs under (already scoped for an unattended Turn).
    .PARAMETER TurnParameter
        The Invoke-Shp parameters of the Turn, approval binding included.
    .PARAMETER Catalog
        The Turn's Subagent catalog from Get-DpSubagentCatalog.
    .PARAMETER WorkingDirectory
        The Turn's working directory.
    .PARAMETER EngineSupported
        Whether the Engine exposes the bounded Subagent contract.
    .OUTPUTS
        System.Collections.Hashtable

        enabled, reason and context (catalog, capability, turn, limits, state).
    #>
    [CmdletBinding()]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds and returns in-memory data; it changes no state.')]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Settings,

        [Parameter(Mandatory)]
        [hashtable]$TurnParameter,

        [Parameter(Mandatory)]
        [hashtable]$Catalog,

        [AllowEmptyString()]
        [string]$WorkingDirectory,

        [bool]$EngineSupported
    )

    $off = { param([string]$Reason) @{ enabled = $false; reason = $Reason; context = $null } }
    $permissions = $Settings.permissions
    if (-not [bool](Get-DpPropertyValue -InputObject $permissions -Name 'subagents' -Default $false)) {
        return (& $off 'The Subagents Permission is off.')
    }
    if (-not [bool](Get-DpPropertyValue -InputObject $permissions -Name 'userTools' -Default $false)) {
        return (& $off 'Subagents need the User Tools Permission, because run_subagent is a User Tool.')
    }
    if (-not $EngineSupported) {
        return (& $off 'This Engine has no bounded Subagent contract. Update ShellPilot to use Subagents.')
    }
    if ($TurnParameter.ContainsKey('ToolCallApprover')) {
        return (& $off 'This Engine approves Tools through ToolCallApprover, which a Subagent cannot inherit, so Subagents stay off.')
    }
    if (-not $Catalog.allowed) { return (& $off ([string]$Catalog.reason)) }
    $entries = @($Catalog.entries)
    if ($entries.Count -eq 0) { return (& $off 'No Subagent is available.') }

    $capability = @{}
    foreach ($switch in 'DisableFileAccess', 'DisableTerminal', 'DisableBrowsing', 'DisableMcp', 'DisableUserTools') {
        $capability[$switch] = [bool]$TurnParameter[$switch]
    }
    if ($TurnParameter.ContainsKey('ToolCallControl')) { $capability['ToolCallControl'] = $TurnParameter['ToolCallControl'] }

    # Withheld from every Subagent: no Subagent of its own, and nobody to ask.
    # Only names the Turn registered, because the Engine refuses an unknown one.
    $exclude = @('run_subagent')
    if ([bool](Get-DpPropertyValue -InputObject $permissions -Name 'askUser' -Default $false)) { $exclude += 'ask_questions' }

    @{
        enabled = $true
        reason  = ''
        context = @{
            catalog    = $entries
            capability = $capability
            turn       = @{
                model            = [string]$TurnParameter['Model']
                reasoningEffort  = [string]$TurnParameter['ReasoningEffort']
                workingDirectory = $WorkingDirectory
                excludeTool      = $exclude
            }
            limits     = (Get-DpSubagentLimit -MaxToolIterations ([int](Get-DpPropertyValue -InputObject $Settings -Name 'maxToolIterations' -Default 50)))
            state      = @{ runs = 0; spentUSD = 0.0; active = $null }
        }
    }
}
