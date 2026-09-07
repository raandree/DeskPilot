function Initialize-DpTerminalTool {
    <#
    .SYNOPSIS
        Registers DeskPilot's gated terminal Tool in place of the Engine's.
    .DESCRIPTION
        Half of the per-call approval boundary. The other half is
        -DisableTerminal on the Turn, which stops the Engine offering its own
        run_command and - from the build this probes for - stops it dispatching
        one anyway.

        The Tool is deliberately NOT named run_command. ShellPilot dispatches its
        built-ins from literal switch clauses and reaches registered Tools only
        through that switch's default, so a Tool sharing a built-in's name is
        advertised to the Model and then never invoked while the built-in runs
        the command ungated. The name is the boundary.

        What is registered is DeskPilot's Invoke-DpTerminalApprovalTool,
        re-declared inside the Engine Runspace from its own definition, exactly as
        the workspace Tools are: the runspace has ShellPilot imported and
        DeskPilot not, so anything the Tool calls must be injected beside it.

        Execution is delegated, not reimplemented. The executor scriptblock is
        built **inside** the runspace - scriptblocks carry runspace affinity, so
        one created here would fail there - and calls the Engine's own
        Invoke-RunCommandTool through the module's session state. DeskPilot
        therefore owns the decision and the Engine keeps the child process,
        deadline, output caps and process-tree kill it already had.

        The probe is a capability probe, not a version comparison: if that private
        function is not in this build of the Engine, registration fails loudly
        here rather than the Tool refusing every command later for reasons the
        user cannot see.

        Runspace globals carry what must not be a Tool parameter. The Turn context
        and the safe-list are the load-bearing ones: as parameters they would be
        fields in the JSON schema the model fills in, which would let it name its
        own working directory and hand itself its own allow-list.
    .PARAMETER Runspace
        The long-lived Engine Runspace with ShellPilot already imported.
    .PARAMETER Context
        conversationId, turnId, project and workingDirectory for this Turn.
    .PARAMETER SafeCommand
        The effective safe-list: shipped entries plus validated user additions.
    .PARAMETER TimeoutMinutes
        How long an unanswered approval waits before it is denied.
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Runspaces.Runspace]$Runspace,

        [Parameter(Mandatory)]
        [hashtable]$Context,

        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$SafeCommand,

        [ValidateRange(1, 1440)]
        [int]$TimeoutMinutes = 15,

        [Parameter(Mandatory)]
        [object]$Bridge,

        [object]$IsolatedSession
    )

    if ($Context.ContainsKey('terminalExecution') -and $Context.terminalExecution.mode -eq 'isolated' -and $null -eq $IsolatedSession) {
        $IsolatedSession = New-DpIsolatedTerminalSession -Context $Context
    }

    $names = @(
        'Get-DpPropertyValue'
        'ConvertTo-DpTerminalExecution'
        'New-DpApprovalRequest'
        'Test-DpCommandSafe'
        'Invoke-DpTerminalApprovalTool'
    )

    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.AppendLine('param($Context, $SafeCommand, [int]$TimeoutMinutes, $Bridge, $IsolatedSession)')
    [void]$builder.AppendLine('Set-Variable -Name DeskPilotIsolatedTerminal -Scope Global -Value $IsolatedSession')
    [void]$builder.AppendLine('Set-Variable -Name DeskPilotApprovalContext -Scope Global -Value $Context')
    [void]$builder.AppendLine('Set-Variable -Name DeskPilotSafeCommand -Scope Global -Value @($SafeCommand)')
    [void]$builder.AppendLine('Set-Variable -Name DeskPilotApprovalTimeoutMinutes -Scope Global -Value $TimeoutMinutes')
    [void]$builder.AppendLine('Set-Variable -Name DeskPilotApprovalBridge -Scope Global -Value $Bridge')

    foreach ($name in $names) {
        $command = Get-Command -Name $name -CommandType Function -ErrorAction Stop
        [void]$builder.AppendLine("function global:$name {")
        [void]$builder.AppendLine($command.Definition)
        [void]$builder.AppendLine('}')
    }

    # Single-quoted: this text is the runspace's own source, not DeskPilot's.
    [void]$builder.AppendLine(@'
$engine = Get-Module -Name ShellPilot | Select-Object -First 1
if (-not $engine) { throw 'ShellPilot is not loaded in the engine runspace.' }
if (-not (& $engine { Get-Command -Name Invoke-RunCommandTool -CommandType Function -ErrorAction SilentlyContinue })) {
    throw 'This build of ShellPilot has no Invoke-RunCommandTool, so DeskPilot cannot run approved commands.'
}
# Approval only holds if the Engine refuses to dispatch a built-in it did not
# offer. Without that, -DisableTerminal bounds what the Model is shown and
# nothing about what runs, so a run_command call the Model makes from its own
# priors or from a replayed history executes beside the gate. Probed from source
# for the same reason as the check above: a missing capability must fail here,
# loudly, rather than leave a gate that reports as active and is not. Failing to
# find the marker refuses the boundary, which is the safe direction.
if ((& $engine { (Get-Command -Name Invoke-Shp).Definition }) -notmatch 'offeredBuiltInTool') {
    throw 'This build of ShellPilot still dispatches disabled built-in tools, so DeskPilot cannot guarantee that a command reaches the approval gate. Update ShellPilot, or switch per-call approval off.'
}

# Built here so it belongs to this runspace, and closes over the module so the
# private Engine function stays reachable.
Set-Variable -Name DeskPilotTerminalExecutor -Scope Global -Value {
    param($Command, $WorkingDirectory, $TimeoutSeconds)
    if ($null -ne $global:DeskPilotIsolatedTerminal) {
        return $global:DeskPilotIsolatedTerminal.Run($Command, $WorkingDirectory, $TimeoutSeconds)
    }
    $module = Get-Module -Name ShellPilot | Select-Object -First 1
    & $module {
        param($Command, $WorkingDirectory, $TimeoutSeconds)
        if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) {
            Invoke-RunCommandTool -Command $Command -TimeoutSeconds $TimeoutSeconds
        }
        else {
            Invoke-RunCommandTool -Command $Command -WorkingDirectory $WorkingDirectory -TimeoutSeconds $TimeoutSeconds
        }
    } $Command $WorkingDirectory $TimeoutSeconds
}

$runDescription = @"
Run a shell command on the user's computer. Every command you propose is shown to
the user for approval before it runs, unless it is on their list of commands that
never need asking (routine read-only ones such as git status) or they explicitly
approved Terminal for this Turn in the same working directory and execution
policy. That grant expires on Stop, Turn completion or scope revocation. Approval
is not a formality: the user can decline, and a declined command does NOT run.
Because of that, prefer the tools that need no approval and do the job better:
search_files and search_text instead of dir, ls, find, grep or Select-String, and
read_file instead of cat or Get-Content.
When you do need this tool, propose ONE command that does one thing. A long chain
is harder for the user to approve, and if they decline it you learn nothing about
which part they objected to.
command (string, required): the command line, interpreted by PowerShell 7.
workingDirectory (string, optional): where to run it. Defaults to the user's
selected project folder, which is almost always what you want.
timeoutSeconds (integer, optional): seconds before the command is killed.
Defaults to 120.
Returns JSON {approved, result} when it ran, where result is the command's own
{exitCode, stdout, stderr} envelope. Returns {approved:false, error} when it did
not run - because the user declined, because nobody answered in time, or because
terminal access is unavailable. A declined command is an answer, not a failure:
read the message, and either propose a different approach or explain why you need
this one. Do NOT re-propose the same command hoping for a different answer.
"@

Register-ShpTool -Command 'Invoke-DpTerminalApprovalTool' -ToolName 'run_terminal_command' -Description $runDescription -Confirm:$false
'@)

    if ($null -ne $IsolatedSession) {
        [void]$builder.AppendLine(@'
$isolatedDescription = @"
Run one PowerShell command in a disposable Linux container, never on the Windows host.
The selected Project is mounted at /project. Use Project-relative paths or /project
as workingDirectory. Network is off unless the user selected exact HTTPS origins;
then use the supplied HTTPS proxy and temporary CA. Direct TCP, DNS, SSH and UDP
are denied. Host programs, host credentials and host paths are unavailable.
The user approves commands outside their safe-list before any command starts,
either once or explicitly for this Turn in the same directory and execution
policy. A Turn grant never changes mounts, network grants, credentials or limits.
Returns JSON {approved,result}; result carries exitCode, stdout, stderr, failure
flags, cleanupSucceeded and Project-relative filesWritten. Do not retry a denied
command or propose changing execution mode. File, Browsing, MCP and Intercom are
separate Tools and are not isolated by this Terminal boundary.
"@
Register-ShpTool -Command 'Invoke-DpTerminalApprovalTool' -ToolName 'run_terminal_command' -Description $isolatedDescription -Confirm:$false
'@)
    }

    $shell = [powershell]::Create()
    $shell.Runspace = $Runspace
    try {
        $null = $shell.AddScript($builder.ToString()).
            AddArgument($Context).
            AddArgument(@($SafeCommand)).
            AddArgument([int]$TimeoutMinutes).
            AddArgument($Bridge).
            AddArgument($IsolatedSession)
        $shell.Invoke() | Out-Null
        if ($shell.HadErrors) {
            $firstError = $shell.Streams.Error | Select-Object -First 1
            throw $(if ($firstError) { $firstError.ToString() } else { 'Could not register the approval-gated terminal tool.' })
        }
    }
    finally {
        $shell.Dispose()
    }

    $true
}
