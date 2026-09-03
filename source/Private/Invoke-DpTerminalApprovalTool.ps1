function Invoke-DpTerminalApprovalTool {
    <#
    .SYNOPSIS
        The DeskPilot-owned run_command Tool: asks before it acts.
    .DESCRIPTION
        Runs inside the Engine Runspace as a registered User Tool while
        Invoke-Shp is given -DisableTerminal. That pairing is what makes this a
        boundary rather than a preference: with the built-in run_command removed
        from both the offered tool set and the dispatch switch, the Model has
        nothing to fall back to.

        Approval blocks the call, it does not follow it. The function parks on the
        approval bridge - the same rendezvous ask_questions uses - so no command
        has run when the question reaches the user, and the Turn resumes exactly
        where it stopped when the answer arrives.

        Execution itself is delegated to the Engine's own run_command
        implementation through the injected executor. DeskPilot owns the gate; it
        does not re-implement process spawning, deadlines, output caps and tree
        kill, which the Engine already does carefully.

        A denial is a Tool result, never a failed Turn: the Model is told plainly
        that the user declined so it can propose something else.

        This function is re-declared inside the Engine Runspace from its own
        definition, so it may only call functions injected alongside it.
    .PARAMETER Command
        The command line the Model proposes to run.
    .PARAMETER WorkingDirectory
        Where to run it. Defaults to the Project the Turn is bound to.
    .PARAMETER TimeoutSeconds
        Wall-clock limit handed to the executor.
    .OUTPUTS
        System.String - a compact JSON envelope.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Command,

        [string]$WorkingDirectory,

        [ValidateRange(1, 86400)]
        [int]$TimeoutSeconds = 120
    )

    $refuse = {
        param([string]$Message)
        (@{ approved = $false; error = $Message } | ConvertTo-Json -Compress)
    }

    # Runspace globals are how an injected Tool receives what must not become a
    # Tool parameter; read through Get-Variable, like the workspace Tools do.
    $read = {
        param([string]$Name)
        $variable = Get-Variable -Name $Name -Scope Global -ErrorAction SilentlyContinue
        if ($variable) { $variable.Value } else { $null }
    }

    $executor = & $read 'DeskPilotTerminalExecutor'
    if ($null -eq $executor) {
        return (& $refuse 'Terminal execution is not available in this session, so nothing was run.')
    }

    $bridge = & $read 'DeskPilotApprovalBridge'
    if ($null -eq $bridge -or -not $bridge.Enabled) {
        return (& $refuse 'DeskPilot cannot ask the user to approve this command right now, so it was not run.')
    }

    $context = & $read 'DeskPilotApprovalContext'
    $directory = if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) { [string]$context.workingDirectory } else { $WorkingDirectory }

    $request = New-DpApprovalRequest -Tool 'run_command' -Class 'Terminal' `
        -Argument @{ command = $Command; workingDirectory = $directory } `
        -ProjectName ([string]$context.project) `
        -ConversationId ([string]$context.conversationId) `
        -TurnId ([string]$context.turnId)

    $resolved = Resolve-DpApprovalGrant -State (& $read 'DeskPilotApprovalState') -Request $request
    Set-Variable -Name 'DeskPilotApprovalState' -Scope Global -Value $resolved.state

    if (-not $resolved.approved) {
        $bridge.CaptureQuestion(($request | ConvertTo-Json -Depth 6 -Compress))

        $answerText = ''
        try { $answerText = $bridge.RequestAnswer() }
        catch { return (& $refuse 'The turn was stopped before this command was approved, so it was not run.') }

        $answer = $null
        try { $answer = $answerText | ConvertFrom-Json -ErrorAction Stop } catch { $answer = $null }

        $decision = if ($answer -and $answer.PSObject.Properties['decision']) { [string]$answer.decision } else { 'deny' }
        if ($decision -ne 'approve') {
            return (& $refuse 'The user declined this command, so it was not run. Suggest a different approach, or explain why it is needed.')
        }

        $scope = if ($answer.PSObject.Properties['scope']) { [string]$answer.scope } else { 'once' }
        if ($scope -eq 'turn') {
            Set-Variable -Name 'DeskPilotApprovalState' -Scope Global `
                -Value (Add-DpApprovalGrant -State (& $read 'DeskPilotApprovalState') -Request $request -Scope 'turn')
        }
    }

    $output = ''
    try { $output = & $executor $Command $directory $TimeoutSeconds }
    catch { return (& $refuse "The command was approved but did not run: $_") }

    (@{ approved = $true; result = [string]$output } | ConvertTo-Json -Compress)
}
