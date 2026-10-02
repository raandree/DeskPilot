function ConvertTo-DpSubagentTurnParameter {
    <#
    .SYNOPSIS
        Turns the Engine's attenuated Subagent request into the Invoke-Shp
        parameters of the Subagent's own Turn.
    .DESCRIPTION
        Invoke-ShpSubagent resolves what a Subagent may do - the strict subset of
        the dispatching Turn - and hands that request to an Invoker. Its own
        dispatcher, Invoke-ShpSubagentTurn, binds the request onto Invoke-Shp but
        has no Model, so a Subagent would run on the Engine's session default
        rather than the Model the user chose for this Turn.

        This is that dispatcher with DeskPilot's few additions. Every parameter
        the Engine binds is bound here identically, and the inherited controls -
        the Tool policy, the decision control, the execution contract - are
        handed over as the objects themselves. A test compares the two against
        the installed Engine, so a control the Engine starts binding cannot be
        silently left out here.

        DeskPilot adds only what keeps the Subagent on the Turn's identity or takes
        capability away from it:
        - Model and ReasoningEffort from the Turn.
        - DisableTodoList, because a Subagent's Task List would replace the
          Turn's own in the window.
        - The Turn's excluded Tools (run_subagent and ask_questions): withheld
          through ExcludeTool from an unbound tool set, or removed from a bound
          one. The Engine refuses to dispatch a known Tool it did not offer, so
          this is enforcement, not advice.
        - A note naming the working directory, appended after the Agent body.
    .PARAMETER Request
        The attenuated request Invoke-ShpSubagent passes to its Invoker.
    .PARAMETER Turn
        model, reasoningEffort, workingDirectory and excludeTool for the Turn
        that dispatched the Subagent.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Request,

        [Parameter(Mandatory)]
        [hashtable]$Turn
    )

    # The Engine's own translation, key for key (Invoke-ShpSubagentTurn).
    $parameters = @{
        Prompt             = [string]$Request['Prompt']
        History            = @()
        NonInteractive     = $true
        DisableUserPrompts = $true
        DisableStreaming   = $true
        MaxToolIterations  = [int]$Request['MaxToolIterations']
        TraceParent        = [string]$Request['TraceParent']
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Request['SystemPrompt'])) { $parameters['AppendSystemPrompt'] = [string]$Request['SystemPrompt'] }
    $named = @(@($Request['Tool']) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $toolBound = if ($null -ne $Request['ToolBound']) { [bool]$Request['ToolBound'] } else { $named.Count -gt 0 }
    if ($toolBound) { $parameters['Tool'] = $named }
    if ([double]$Request['MaxBudgetUSD'] -gt 0) { $parameters['MaxBudgetUSD'] = [double]$Request['MaxBudgetUSD'] }
    foreach ($switch in 'DisableFileAccess', 'DisableTerminal', 'DisableBrowsing', 'DisableMcp', 'DisableUserTools', 'AllowPrivateNetwork', 'DisableRedaction') {
        if ($Request[$switch]) { $parameters[$switch] = $true }
    }
    if ($Request['ToolPolicy']) { $parameters['ToolPolicy'] = $Request['ToolPolicy'] }
    if ($Request['ToolCallControl']) { $parameters['ToolCallControl'] = $Request['ToolCallControl'] }
    if ($Request['ExecutionContract'] -is [scriptblock]) { $parameters['ExecutionContract'] = $Request['ExecutionContract'] }
    if (-not [string]::IsNullOrWhiteSpace([string]$Request['ApiBase'])) { $parameters['ApiBase'] = [string]$Request['ApiBase'] }
    if ($Request['CancellationToken'] -is [System.Threading.CancellationToken]) { $parameters['CancellationToken'] = $Request['CancellationToken'] }
    if ($Request['Deadline'] -is [datetime]) { $parameters['Deadline'] = [datetime]$Request['Deadline'] }

    # DeskPilot's additions: the Turn's identity, and capability taken away.
    if (-not [string]::IsNullOrWhiteSpace([string]$Turn['model'])) { $parameters['Model'] = [string]$Turn['model'] }
    if (-not [string]::IsNullOrWhiteSpace([string]$Turn['reasoningEffort'])) { $parameters['ReasoningEffort'] = [string]$Turn['reasoningEffort'] }
    $parameters['DisableTodoList'] = $true
    $withheld = @(@($Turn['excludeTool']) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($withheld.Count -gt 0) {
        if ($toolBound) { $parameters['Tool'] = @($named | Where-Object { $_ -notin $withheld }) }
        else { $parameters['ExcludeTool'] = $withheld }
    }

    $directory = [string]$Turn['workingDirectory']
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        $note = "DeskPilot dispatched you as a Subagent. Your working directory is $directory; resolve relative paths against it."
        $parameters['AppendSystemPrompt'] = if ($parameters.ContainsKey('AppendSystemPrompt')) { $parameters['AppendSystemPrompt'] + "`n`n" + $note } else { $note }
    }

    $parameters
}
