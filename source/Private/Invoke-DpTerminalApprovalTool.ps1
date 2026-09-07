function Invoke-DpTerminalApprovalTool {
    <#
    .SYNOPSIS
        DeskPilot's own terminal Tool: asks before it acts.
    .DESCRIPTION
        Runs inside the Engine Runspace as a registered User Tool named
        run_terminal_command, while Invoke-Shp is given -DisableTerminal. The
        name matters: a User Tool called run_command would be shadowed by the
        Engine's built-in dispatch clause and never invoked at all.

        Three properties, in the order they are enforced:

        1. **The safe-list decides whether you are interrupted.** A command that
           positively matches runs without a prompt. Everything else prompts,
           including everything the list has never heard of - the tier fails
           closed, so its errors land on the safe side.
        2. **Approval blocks the call, it does not follow it.** The function
           parks on the approval bridge, the same rendezvous ask_questions uses,
           so no command has run when the question reaches the user.
          3. **Turn-wide approval is explicit and scoped.** Allow once remains the
              default. Allow for this Turn covers later Terminal commands only in
              the same Conversation, Turn, Project, working directory and execution
              policy. Stop or the Turn boundary clears the in-memory grant.

        Execution is delegated to the Engine's own run_command through the
        injected executor. DeskPilot owns the gate; it does not re-implement
        process spawning, deadlines, output caps and tree kill.

        A denial is a Tool result, never a failed Turn, and carries the user's
        optional note so a refusal can steer rather than dead-end.

        Re-declared inside the Engine Runspace from its own definition, so it may
        only call functions injected alongside it.
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

    $context = & $read 'DeskPilotApprovalContext'
    $directory = if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) { [string]$context.workingDirectory } else { $WorkingDirectory }
    $isolated = & $read 'DeskPilotIsolatedTerminal'
    if ($null -ne $isolated) {
        try { $directory = $isolated.MapWorkingDirectory($directory) }
        catch { return (& $refuse $_.Exception.Message) }
    }

    $bridge = & $read 'DeskPilotApprovalBridge'
    $approvalScope = 'once'
    $approvalSource = 'prompt'
    $recordApproval = {
        param([string]$Status, [string]$Scope, [string]$Source)
        Write-Information -Tags 'DeskPilotApproval' -MessageData ([pscustomobject]@{
            Kind = 'TerminalApproval'; Status = $Status; Scope = $Scope; Source = $Source
            ConversationId = [string]$context.conversationId; TurnId = [string]$context.turnId
        })
    }
    $run = {
        if ($bridge -and $bridge.Cancelled) {
            & $recordApproval 'denied' 'once' 'cancelled'
            return (& $refuse 'Terminal approval was cancelled, so nothing was run.')
        }
        if ($approvalSource -cne 'safe-list') { & $recordApproval 'approved' $approvalScope $approvalSource }
        $output = ''
        try { $output = & $executor $Command $directory $TimeoutSeconds }
        catch { return (& $refuse "The command was approved but did not run: $_") }
        (@{ approved = $true; approvalScope = $approvalScope; approvalSource = $approvalSource; result = [string]$output } | ConvertTo-Json -Compress)
    }

    # An absent or corrupt list yields an empty list, so everything prompts.
    $safeList = @(& $read 'DeskPilotSafeCommand')
    if (Test-DpCommandSafe -Command $Command -SafeCommand $safeList) {
        $approvalSource = 'safe-list'
        return (& $run)
    }

    if ($null -eq $bridge -or -not $bridge.Enabled -or $bridge.Cancelled) {
        return (& $refuse 'DeskPilot cannot ask the user to approve this command right now, so it was not run.')
    }

    $request = New-DpApprovalRequest -Tool 'run_terminal_command' -Class 'Terminal' `
        -Argument @{ command = $Command; workingDirectory = $directory; execution = $context.terminalExecution; policyId = $context.policyId } `
        -ProjectName ([string]$context.project) `
        -ConversationId ([string]$context.conversationId) `
        -TurnId ([string]$context.turnId)

    if ($bridge.HasTurnScope([string]$context.conversationId, $request.scopeFingerprint)) {
        $approvalScope = 'turn'
        $approvalSource = 'turn-grant'
        return (& $run)
    }
    & $recordApproval 'requested' 'once' 'prompt'
    $bridge.CaptureQuestion(($request | ConvertTo-Json -Depth 6 -Compress))

    $timeoutMinutes = [int](& $read 'DeskPilotApprovalTimeoutMinutes')
    if ($timeoutMinutes -lt 1) { $timeoutMinutes = 15 }

    $answerText = ''
    try { $answerText = $bridge.RequestAnswer($timeoutMinutes * 60) }
    catch [System.TimeoutException] {
        & $recordApproval 'denied' 'once' 'timeout'
        return (& $refuse "Nobody approved this command within $timeoutMinutes minute(s), so it was not run.")
    }
    catch {
        & $recordApproval 'denied' 'once' 'cancelled'
        return (& $refuse 'The turn was stopped before this command was approved, so it was not run.')
    }

    $answer = $null
    try { $answer = $answerText | ConvertFrom-Json -ErrorAction Stop } catch { $answer = $null }

    $decision = if ($answer -and $answer.PSObject.Properties['decision']) { [string]$answer.decision } else { 'deny' }
    if ($decision -ne 'approve') {
        & $recordApproval 'denied' 'once' 'prompt'
        $note = if ($answer -and $answer.PSObject.Properties['note']) { ([string]$answer.note).Trim() } else { '' }
        $message = 'The user declined this command, so it was not run.'
        $message += if ($note) { " They said: $note" } else { ' Suggest a different approach, or explain why it is needed.' }
        return (& $refuse $message)
    }

    $scope = 'once'
    if ($answer.PSObject.Properties['scope']) { $scope = $answer.scope }
    if ($scope -isnot [string] -or $scope -cnotin @('once', 'turn')) {
        return (& $refuse 'The approval scope was invalid, so nothing was run.')
    }
    if (-not $bridge.Enabled -or $bridge.Cancelled) {
        return (& $refuse 'The Turn ended before this command was approved, so nothing was run.')
    }
    if ($scope -ceq 'turn' -and -not $bridge.GrantTurnScope([string]$context.conversationId, $request.scopeFingerprint)) {
        return (& $refuse 'The Turn-wide approval is no longer valid, so nothing was run.')
    }
    $approvalScope = $scope
    & $run
}
