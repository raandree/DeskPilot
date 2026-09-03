function New-DpApprovalRequest {
    <#
    .SYNOPSIS
        Builds one redacted, correlated approval request.
    .DESCRIPTION
        The question DeskPilot puts to the user before a risky Tool call runs.
        Two properties make it safe to show and safe to answer.

        **The summary is an allow-list, not a copy.** Only fields this function
        names are carried; anything else the Model supplied contributes nothing.
        A blacklist would have to be right about every future argument, and the
        arguments are exactly where a token or a file body would be.

        **The fingerprint binds the answer to one action.** It covers the Tool,
        the class, the Conversation, the Turn and the exact command, so an answer
        cannot be replayed against a different command, a different chat, or a
        later Turn - the request id alone would not stop a stale grant matching.
    .PARAMETER Tool
        The Tool name offered to the Model.
    .PARAMETER Class
        The narrow class an approval may be scoped to.
    .PARAMETER Argument
        The Tool arguments. Only allow-listed keys are read.
    .PARAMETER ProjectName
        The Project the action affects, for display.
    .PARAMETER ConversationId
        The Conversation this request belongs to.
    .PARAMETER TurnId
        The Turn this request belongs to.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Tool,

        [Parameter(Mandatory)]
        [ValidateSet('Terminal', 'FileWrite', 'Mcp', 'UserTool')]
        [string]$Class,

        [Parameter(Mandatory)]
        [hashtable]$Argument,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$ProjectName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ConversationId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$TurnId
    )

    $maxCommand = 2000
    $command = if ($Argument.ContainsKey('command')) { [string]$Argument['command'] } else { '' }
    $workingDirectory = if ($Argument.ContainsKey('workingDirectory')) { [string]$Argument['workingDirectory'] } else { '' }

    $shown = $command
    if ($shown.Length -gt $maxCommand) {
        $shown = $shown.Substring(0, $maxCommand) + " ...[truncated, $($command.Length) characters]"
    }

    $material = @($Tool, $Class, $ConversationId, $TurnId, $command.Trim(), $workingDirectory.Trim()) -join [char]31
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $digest = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($material)) }
    finally { $sha.Dispose() }
    $fingerprint = -join ($digest | ForEach-Object { $_.ToString('x2') })

    $risk = switch ($Class) {
        'Terminal' { 'This runs a command on your computer with your account. It can read, change or delete files, and it can reach the network.' }
        'FileWrite' { 'This writes to a file outside the project folder, where DeskPilot cannot undo it for you.' }
        'Mcp' { 'This calls an attached tool that may change something outside DeskPilot.' }
        default { 'This performs an action that may change something on your computer.' }
    }

    @{
        id             = [guid]::NewGuid().ToString('N')
        tool           = $Tool
        class          = $Class
        conversationId = $ConversationId
        turnId         = $TurnId
        fingerprint    = $fingerprint
        summary        = @{
            command          = $shown
            workingDirectory = $workingDirectory
            project          = [string]$ProjectName
        }
        risk           = $risk
        requestedUtc   = [datetime]::UtcNow.ToString('o')
    }
}
