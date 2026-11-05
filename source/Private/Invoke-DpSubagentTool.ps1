function Invoke-DpSubagentTool {
    <#
    .SYNOPSIS
        DeskPilot's run_subagent Tool: runs one bounded Subagent and returns its
        report.
    .DESCRIPTION
        Runs inside the Engine Runspace as the User Tool run_subagent. The Model
        names a Subagent and a task; the Engine's Invoke-ShpSubagent runs it as a
        nested Turn that is a strict subset of the Turn that dispatched it, inside
        the budget DeskPilot gives it, and hands back an answer rather than a
        transcript.

        Everything that decides what the Subagent may do comes from the
        Host-built DeskPilotSubagentContext global, never from a Tool argument:
        the catalog maps a name to a definition path, so a name the Model invents
        reaches no file; the capability carries the Turn's switches and approval
        control; the Turn block carries the Model and the Tools to withhold.

        The definition's own tools list is set aside (Capability Tool = $null):
        DeskPilot Agents are personas, their tools lists use VS Code names the
        Engine does not know, and the Permissions decide what an Agent may use.
        The Subagent therefore gets the Turn's Tools, minus run_subagent and
        ask_questions, and never more.

        One Subagent runs at a time and none may start another. A Turn may start
        a fixed number, within a cost cap kept on a per-Turn ledger. Each run is
        announced before it starts and accounted for when it ends, as
        DeskPilotSubagent Information records the Host Server turns into the
        Activity the window shows. A refusal, a failure and a cancellation are
        Tool results, never a failed Turn.

        Re-declared inside the Engine Runspace from its own definition, so it may
        only call functions injected alongside it.
    .PARAMETER Prompt
        The complete task for the Subagent.
    .PARAMETER Agent
        The catalog name of the Subagent. Empty means general-purpose.
    .PARAMETER Description
        A short label the user sees.
    .OUTPUTS
        System.String - a compact JSON envelope.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Prompt,

        [string]$Agent,

        [string]$Description
    )

    $variable = Get-Variable -Name 'DeskPilotSubagentContext' -Scope Global -ErrorAction SilentlyContinue
    $context = if ($variable) { $variable.Value } else { $null }
    if ($null -eq $context) {
        return (@{ status = 'unavailable'; error = 'Subagents are not available in this Turn.' } | ConvertTo-Json -Compress)
    }
    $limits = $context.limits
    $state = $context.state

    $clip = {
        param([string]$Text, [int]$Max)
        if ([string]::IsNullOrEmpty($Text) -or $Text.Length -le $Max) { return [string]$Text }
        $Text.Substring(0, $Max) + "`n[... $($Text.Length - $Max) more characters not shown]"
    }
    $flatten = {
        param([string]$Text, [int]$Max)
        $flat = (([string]$Text -replace '[\x00-\x1f\x7f]+', ' ') -replace '\s+', ' ').Trim()
        if ($flat.Length -gt $Max) { $flat = $flat.Substring(0, $Max - 1).TrimEnd() + [char]0x2026 }
        $flat
    }

    $agentName = if ([string]::IsNullOrWhiteSpace($Agent)) { 'general-purpose' } else { & $flatten $Agent 64 }
    $entry = @($context.catalog) | Where-Object { $_.name -eq $agentName } | Select-Object -First 1
    if ($entry) { $agentName = [string]$entry.name }
    $runId = 'a_' + [guid]::NewGuid().ToString('N').Substring(0, 16)
    $record = {
        param([hashtable]$Data)
        $Data['Id'] = $runId
        $Data['Agent'] = $agentName
        # Pinned: these records are how the Host Server accounts for the run, so a
        # caller's InformationAction or preference must not be able to drop them.
        Write-Information -MessageData ([pscustomobject]$Data) -Tags 'DeskPilotSubagent' -InformationAction SilentlyContinue
    }
    $finish = {
        param([string]$Status, [string]$Reason, [string]$Answer, [hashtable]$Stats)
        $data = @{
            Phase  = 'finished'
            Status = $Status
            Reason = (& $flatten $Reason 500)
            Output = (& $clip $Answer ([int]$limits.maxOutputChars))
        }
        if ($Stats) { foreach ($key in $Stats.Keys) { $data[$key] = $Stats[$key] } }
        & $record $data
        $reply = [ordered]@{ status = $Status; agent = $agentName }
        if ($Status -eq 'completed') { $reply['answer'] = & $clip $Answer ([int]$limits.maxAnswerChars) }
        else { $reply['error'] = $Reason }
        $reply | ConvertTo-Json -Compress
    }

    & $record @{
        Phase       = 'started'
        Description = (& $flatten $Description ([int]$limits.maxDescriptionChars))
        Input       = (& $clip $Prompt ([int]$limits.maxInputChars))
    }

    $refusal = if ($state.active) {
        'A Subagent cannot dispatch another Subagent. Do this part of the task yourself.'
    }
    elseif ($null -eq $entry) {
        "There is no Subagent called '$agentName'. Choose one of: $((@($context.catalog) | ForEach-Object { $_.name }) -join ', ')."
    }
    elseif ($Prompt.Length -gt [int]$limits.maxPromptChars) {
        "The task is $($Prompt.Length) characters long; a Subagent task may be at most $($limits.maxPromptChars). Put the detail in a file and name the file in the task."
    }
    elseif ([int]$state.runs -ge [int]$limits.maxRuns) {
        "This Turn has already run $($state.runs) Subagents, the most one Turn may run. Finish the rest yourself."
    }
    elseif ([double]$state.spentUSD -ge [double]$limits.maxTurnUSD) {
        "This Turn's Subagent budget of USD $($limits.maxTurnUSD) is spent. Finish the rest yourself."
    }
    else { '' }
    if ($refusal) { return (& $finish 'refused' $refusal '' $null) }

    # The Engine's own commands, read from this runspace's function table. A
    # lookup by name could import another installed copy of the Engine, which
    # replaces the commands this Tool and its Turn run on.
    $engineCommand = {
        param([string]$Name)
        Get-Item -LiteralPath "function:$Name" -ErrorAction SilentlyContinue
    }

    # Withhold only what the Engine knows: it refuses an unregistered name. A list
    # that cannot be read leaves nothing to withhold, so nothing runs.
    $registered = $null
    try {
        $listTools = & $engineCommand 'Get-ShpTool'
        if (-not $listTools) { throw 'The Engine has no Get-ShpTool.' }
        $registered = & {
            $ErrorActionPreference = 'Stop'
            @(& $listTools -Origin User | ForEach-Object { [string]$_.Name })
        }
    }
    catch {
        return (& $finish 'failed' ('The Subagent could not run: the Engine''s Tool list could not be read, so the Tools a Subagent must not have could not be withheld. ' + $_.Exception.Message) '' $null)
    }

    $state.active = $runId
    $state.runs = [int]$state.runs + 1
    $runUSD = [Math]::Round([Math]::Min([double]$limits.maxChildUSD, [double]$limits.maxTurnUSD - [double]$state.spentUSD), 6)

    $turn = @{}
    foreach ($key in $context.turn.Keys) { $turn[$key] = $context.turn[$key] }
    $turn['excludeTool'] = @(@($context.turn.excludeTool) | Where-Object { $_ -in $registered })

    $capture = @{ result = $null; invoked = $false }
    $invoker = {
        param($Request)
        $parameters = ConvertTo-DpSubagentTurnParameter -Request $Request -Turn $turn
        $capture['invoked'] = $true
        $turnResult = Invoke-Shp @parameters
        $capture['result'] = $turnResult
        $turnResult
    }.GetNewClosure()

    # What the Engine's Usage log says has been spent so far. A run that throws at
    # its iteration cap or deadline returns no result to read a cost from, but it
    # was billed all the same.
    $measureSpend = {
        try {
            $usage = & $engineCommand 'Get-ShpUsage'
            if (-not $usage) { return $null }
            $summary = & {
                $ErrorActionPreference = 'Stop'
                @(& $usage -Summary)[-1]
            }
            if ($summary -and $summary.PSObject.Properties['CostUSD'] -and $null -ne $summary.CostUSD) { [double]$summary.CostUSD } else { $null }
        }
        catch { $null }
    }

    $spentBefore = & $measureSpend
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $result = $null
    $failure = $null
    try {
        $subagentParams = @{
            DefinitionPath = [string]$entry.path
            Root           = [string]$entry.root
            Prompt         = $Prompt
            Parent         = @{ Capability = $context.capability }
            Capability     = @{ Tool = $null }
            Budget         = @{
                MaxTotalUSD        = $runUSD
                MaxChildUSD        = $runUSD
                MaxTotalIterations = [int]$limits.maxIterations
                MaxChildIterations = [int]$limits.maxIterations
                MaxDepth           = 1
                MaxFanOut          = 1
                MaxConcurrency     = 1
                MaxDurationSec     = [int]$limits.maxDurationSec
            }
            Invoker        = $invoker
        }
        $result = Invoke-ShpSubagent @subagentParams
    }
    catch { $failure = $_ }
    finally {
        $clock.Stop()
        $state.active = $null
    }

    $spentAfter = & $measureSpend
    $turnResult = $capture['result']
    $cost = $null
    if ($turnResult -and $turnResult.PSObject.Properties['CostUSD'] -and $null -ne $turnResult.CostUSD) { $cost = [double]$turnResult.CostUSD }
    if ($null -ne $spentBefore -and $null -ne $spentAfter) {
        $measured = [Math]::Round([double]$spentAfter - [double]$spentBefore, 6)
        if ($measured -gt 0 -and ($null -eq $cost -or $measured -gt $cost)) { $cost = $measured }
    }
    if ($null -ne $cost) { $state.spentUSD = [double]$state.spentUSD + $cost }
    $evidence = if ($result -and $result.PSObject.Properties['Evidence']) { $result.Evidence } else { $null }
    $stats = @{
        DurationMs   = [int]$clock.Elapsed.TotalMilliseconds
        Iterations   = $(if ($evidence) { [int]$evidence.Iterations } else { 0 })
        ToolCalls    = $(if ($evidence) { [int]$evidence.ToolCallCount } else { 0 })
        CostUSD      = $cost
        # Whether the Subagent's Turn reached the Engine, and so wrote a Usage
        # record the dispatching Turn's own Usage has to account for.
        EngineCalls  = [int][bool]$capture['invoked']
        FilesWritten = @(if ($turnResult -and $turnResult.PSObject.Properties['FilesWritten']) { @($turnResult.FilesWritten | ForEach-Object { [string]$_ }) })
    }

    if ($failure) { return (& $finish 'failed' ('The Subagent could not run: ' + $failure.Exception.Message) '' $stats) }
    if ($null -eq $result) { return (& $finish 'failed' 'The Engine returned no Subagent result.' '' $stats) }
    if ($result.Cancelled) { return (& $finish 'cancelled' ([string]$result.Reason) '' $stats) }
    if ($result.Refused) {
        $status = if ([string]$result.Reason -like 'The Subagent failed*') { 'failed' } else { 'refused' }
        return (& $finish $status ([string]$result.Reason) '' $stats)
    }
    & $finish 'completed' '' ([string]$result.Answer) $stats
}
