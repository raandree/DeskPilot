function Invoke-DpToolCallApproval {
    <#
    .SYNOPSIS
        Applies one action-scoped approval to an Engine pre-dispatch request.
    .DESCRIPTION
        Implements specification 120's trusted host callback. It never executes
        a Tool. Missing metadata, denied policy, revoked Permissions, timeout,
        cancellation and malformed answers all refuse dispatch. MCP annotations
        do not grant authority. Complete argument bytes are bound by a digest
        while only known destination fields reach the approval card.
    .PARAMETER Call
        Immutable metadata supplied by the Engine, not by a Model-callable Tool.
    .PARAMETER Context
        The frozen, Host-owned Conversation, Turn, Project and Permissions.
    .PARAMETER Bridge
        The existing approval rendezvous, separate from Ask-User.
    .PARAMETER TimeoutSeconds
        Maximum time to wait for the operator.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Call,
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][AllowNull()][object]$Bridge,
        [ValidateRange(1, 86400)][int]$TimeoutSeconds = 900
    )

    $deny = { param([string]$Message, [string]$Code = 'cancelled'); @{ Allowed = $false; Code = $Code; Message = $Message } }
    $name = Get-DpPropertyValue -InputObject $Call -Name 'Name'
    $class = Get-DpPropertyValue -InputObject $Call -Name 'Class'
    $callId = Get-DpPropertyValue -InputObject $Call -Name 'CallId'
    $json = Get-DpPropertyValue -InputObject $Call -Name 'ArgumentsJson'
    $engineFingerprint = Get-DpPropertyValue -InputObject $Call -Name 'Fingerprint'
    $policy = Get-DpPropertyValue -InputObject $Call -Name 'Policy'
    $allowed = Get-DpPropertyValue -InputObject $policy -Name 'Allowed'
    if ($allowed -isnot [bool] -or -not $allowed) { return (& $deny 'The Engine policy did not allow this Tool call.') }
    if ($name -isnot [string] -or [string]::IsNullOrWhiteSpace($name) -or $name.Length -gt 128 -or
        $name -match '[\x00-\x1f\x7f]' -or $class -isnot [string] -or
        $class -cnotin @('Terminal', 'FileWrite', 'Mcp', 'UserTool') -or
        $callId -isnot [string] -or [string]::IsNullOrWhiteSpace($callId) -or $callId.Length -gt 128 -or
        $engineFingerprint -isnot [string] -or $engineFingerprint -cnotmatch '^[0-9a-f]{64}$' -or
        $json -isnot [string] -or [System.Text.Encoding]::UTF8.GetByteCount($json) -gt 262144) {
        return (& $deny 'Incomplete or oversized Tool approval metadata was refused.')
    }
    try { $arguments = $json | ConvertFrom-Json -AsHashtable -Depth 32 -ErrorAction Stop }
    catch { return (& $deny 'Malformed Tool arguments were refused before approval.') }
    if ($arguments -isnot [System.Collections.IDictionary]) { return (& $deny 'Tool arguments must be an object.') }
    if ($null -eq $Bridge -or -not $Bridge.Enabled -or $Bridge.Cancelled) { return (& $deny 'Tool approval is unavailable or was cancelled.') }

    $permissions = Get-DpPropertyValue -InputObject $Context -Name 'permissions' -Default @{}
    if ($class -ceq 'UserTool' -and -not [bool](Get-DpPropertyValue -InputObject $permissions -Name 'userTools' -Default $false)) {
        return (& $deny 'User Tools Permission is not enabled.')
    }
    if ($name -cin @('write_file', 'create_directory', 'edit_file', 'replace_in_file')) { $class = 'FileWrite' }
    $permission = switch ($class) { 'FileWrite' { 'file' } 'Mcp' { 'mcp' } 'UserTool' { 'userTools' } default { 'terminal' } }
    if (-not [bool](Get-DpPropertyValue -InputObject $permissions -Name $permission -Default $false)) {
        return (& $deny 'The required Tool Permission is not enabled.')
    }
    if ($class -eq 'Terminal') { return (& $deny 'Native Terminal dispatch is unavailable while approval is required.') }
    if ($class -eq 'UserTool') {
        $ownedRead = $name -cin @('search_files', 'search_text') -and
            [bool](Get-DpPropertyValue -InputObject $permissions -Name 'file' -Default $false) -and
            [bool](Get-DpPropertyValue -InputObject $Context -Name 'workspaceToolsOwned' -Default $false)
        $ownedQuestion = $name -ceq 'ask_questions' -and
            [bool](Get-DpPropertyValue -InputObject $permissions -Name 'askUser' -Default $false)
        $ownedTerminal = $name -ceq 'run_terminal_command' -and
            [bool](Get-DpPropertyValue -InputObject $Context -Name 'terminalApprovalActive' -Default $false) -and
            [bool](Get-DpPropertyValue -InputObject $permissions -Name 'terminal' -Default $false)
        if ($ownedRead -or $ownedQuestion -or $ownedTerminal) {
            return @{ Allowed = $true; Code = 'approved'; Message = 'DeskPilot owns this Tool and its applicable gate.' }
        }
    }

    $server = [string](Get-DpPropertyValue -InputObject $Call -Name 'McpServer' -Default '')
    $tool = [string](Get-DpPropertyValue -InputObject $Call -Name 'McpTool' -Default '')
    $summary = @{ action = $name; workingDirectory = [string]$Context.workingDirectory }
    if ($class -eq 'Mcp') {
        if ([string]::IsNullOrWhiteSpace($server) -or [string]::IsNullOrWhiteSpace($tool) -or
            $server.Length -gt 128 -or $tool.Length -gt 128 -or ($server + $tool) -match '[\x00-\x1f\x7f]') {
            return (& $deny 'The MCP server and Tool identity are required for approval.')
        }
        $summary.action = "$server / $tool"
    }
    if ($class -eq 'FileWrite') {
        $path = Get-DpPropertyValue -InputObject $arguments -Name @('path', 'Path', 'filePath')
        if ($path -isnot [string] -or [string]::IsNullOrWhiteSpace($path) -or $path.Length -gt 4096) {
            return (& $deny 'A bounded File destination is required for approval.')
        }
        try { $summary.filePath = [System.IO.Path]::GetFullPath($path, [string]$Context.workingDirectory) }
        catch { return (& $deny 'The File destination could not be resolved for approval.') }
        if ($summary.filePath.Length -gt 4096) { return (& $deny 'The File destination is too long to display for approval.') }
    }

    $material = [ordered]@{
        name = $name; class = $class; callId = $callId; server = $server; tool = $tool
        arguments = $json; engineFingerprint = $engineFingerprint
        workingDirectory = [string]$Context.workingDirectory; project = [string]$Context.project
    } | ConvertTo-Json -Depth 4 -Compress
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $digest = -join ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($material)) | ForEach-Object { $_.ToString('x2') }) }
    finally { $sha.Dispose() }
    $requestParameters = @{
        Tool = $name; Class = $class; Argument = $summary; ActionFingerprint = $digest
        ProjectName = [string]$Context.project; ConversationId = [string]$Context.conversationId; TurnId = [string]$Context.turnId
    }
    $request = New-DpApprovalRequest @requestParameters
    $record = {
        param([string]$Status, [string]$Source = 'prompt')
        Write-Information -Tags 'DeskPilotApproval' -MessageData ([pscustomobject]@{
            Kind = 'ToolApproval'; ToolClass = $class; Status = $Status; Scope = 'once'; Source = $Source
            ConversationId = [string]$Context.conversationId; TurnId = [string]$Context.turnId
        })
    }
    & $record 'requested'
    $Bridge.CaptureQuestion(($request | ConvertTo-Json -Depth 6 -Compress))
    try { $answerText = $Bridge.RequestAnswer($TimeoutSeconds) }
    catch [System.TimeoutException] { & $record 'denied' 'timeout'; return (& $deny 'The Tool approval expired.') }
    catch { & $record 'denied' 'cancelled'; return (& $deny 'The Tool approval was cancelled.') }
    $answer = $null
    try { $answer = $answerText | ConvertFrom-Json -ErrorAction Stop }
    catch { & $record 'denied'; return (& $deny 'An invalid Tool approval answer was refused.') }
    $decision = Get-DpPropertyValue -InputObject $answer -Name 'decision'
    $scope = Get-DpPropertyValue -InputObject $answer -Name 'scope' -Default 'once'
    if ($decision -cne 'approve' -or $scope -cne 'once') {
        & $record 'denied'
        return (& $deny 'The operator did not approve this single Tool action.' 'user_denied')
    }
    if (-not $Bridge.Enabled -or $Bridge.Cancelled) {
        & $record 'denied' 'cancelled'
        return (& $deny 'The Turn ended before Tool approval became authority.')
    }
    & $record 'approved'
    @{ Allowed = $true; Code = 'approved'; Message = 'This exact Tool action was approved once.' }
}
