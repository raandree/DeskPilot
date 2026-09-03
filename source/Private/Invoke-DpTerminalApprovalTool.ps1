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
        3. **There is no Turn-wide grant.** Every command the safe-list does not
           cover is answered on its own merits. Two identical risky commands in
           one Turn ask twice. A class-wide grant would have silently authorised
           every later risky command once one was approved.

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

    $run = {
        $output = ''
        try { $output = & $executor $Command $directory $TimeoutSeconds }
        catch { return (& $refuse "The command was approved but did not run: $_") }
        (@{ approved = $true; result = [string]$output } | ConvertTo-Json -Compress)
    }

    # An absent or corrupt list yields an empty list, so everything prompts.
    $safeList = @(& $read 'DeskPilotSafeCommand')
    if (Test-DpCommandSafe -Command $Command -SafeCommand $safeList) {
        return (& $run)
    }

    $bridge = & $read 'DeskPilotApprovalBridge'
    if ($null -eq $bridge -or -not $bridge.Enabled) {
        return (& $refuse 'DeskPilot cannot ask the user to approve this command right now, so it was not run.')
    }

    $request = New-DpApprovalRequest -Tool 'run_terminal_command' -Class 'Terminal' `
        -Argument @{ command = $Command; workingDirectory = $directory } `
        -ProjectName ([string]$context.project) `
        -ConversationId ([string]$context.conversationId) `
        -TurnId ([string]$context.turnId)

    $bridge.CaptureQuestion(($request | ConvertTo-Json -Depth 6 -Compress))

    $timeoutMinutes = [int](& $read 'DeskPilotApprovalTimeoutMinutes')
    if ($timeoutMinutes -lt 1) { $timeoutMinutes = 15 }

    $answerText = ''
    try { $answerText = $bridge.RequestAnswer($timeoutMinutes * 60) }
    catch [System.TimeoutException] {
        return (& $refuse "Nobody approved this command within $timeoutMinutes minute(s), so it was not run.")
    }
    catch {
        return (& $refuse 'The turn was stopped before this command was approved, so it was not run.')
    }

    $answer = $null
    try { $answer = $answerText | ConvertFrom-Json -ErrorAction Stop } catch { $answer = $null }

    $decision = if ($answer -and $answer.PSObject.Properties['decision']) { [string]$answer.decision } else { 'deny' }
    if ($decision -ne 'approve') {
        $note = if ($answer -and $answer.PSObject.Properties['note']) { ([string]$answer.note).Trim() } else { '' }
        $message = 'The user declined this command, so it was not run.'
        $message += if ($note) { " They said: $note" } else { ' Suggest a different approach, or explain why it is needed.' }
        return (& $refuse $message)
    }

    & $run
}
