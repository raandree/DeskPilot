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
        [ValidateSet('Terminal', 'FileWrite', 'Mcp', 'UserTool', 'BrowserNavigation', 'BrowserAction')]
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
    # A browser navigation is identified by where it goes. The full URL is shown
    # because the query string is where an injected page puts what it is trying
    # to send out - a host alone would hide the payload the user is judging.
    $url = if ($Argument.ContainsKey('url')) { [string]$Argument['url'] } else { '' }
    $targetHost = if ($Argument.ContainsKey('host')) { [string]$Argument['host'] } else { '' }

    # A browser write action is judged on its values, so they are carried rather
    # than summarised away - "submit a form" is not a decision anyone can make.
    # They are bounded, and they are bound into the fingerprint below so an
    # approval for one set of values cannot be spent on another. Credential
    # fields never reach here: the supervisor refuses to fill one at all.
    $action = if ($Argument.ContainsKey('action')) { [string]$Argument['action'] } else { '' }
    $filePath = if ($Argument.ContainsKey('filePath')) { [string]$Argument['filePath'] } else { '' }
    $control = if ($Argument.ContainsKey('control')) { [string]$Argument['control'] } else { '' }
    $fields = @()
    if ($Argument.ContainsKey('fields')) {
        $fields = @(@($Argument['fields']) | Select-Object -First 50 | ForEach-Object {
                $fieldName = [string](Get-DpPropertyValue -InputObject $_ -Name @('name') -Default '')
                $fieldValue = [string](Get-DpPropertyValue -InputObject $_ -Name @('value') -Default '')
                if ($fieldValue.Length -gt 500) {
                    $fieldValue = $fieldValue.Substring(0, 500) + " ...[truncated, $($fieldValue.Length) characters]"
                }
                @{ name = $fieldName; value = $fieldValue }
            })
    }
    $fieldMaterial = ($fields | ForEach-Object { "$($_.name)=$($_.value)" }) -join [char]30

    $execution = @{ mode = 'local' }
    $executionMaterial = ''
    if ($Class -eq 'Terminal') {
        if ($Argument.execution -and $Argument.execution.mode -eq 'isolated') {
            $execution = ConvertTo-DpTerminalExecution -InputObject $Argument.execution
        }
        $canonical = [ordered]@{}
        foreach ($key in @($execution.Keys | Sort-Object)) { $canonical[$key] = $execution[$key] }
        $executionMaterial = ($canonical | ConvertTo-Json -Depth 6 -Compress) + [char]30 + [string]$Argument.policyId
    }

    $shown = $command
    if ($shown.Length -gt $maxCommand) {
        $shown = $shown.Substring(0, $maxCommand) + " ...[truncated, $($command.Length) characters]"
    }

    $shownUrl = $url
    if ($shownUrl.Length -gt $maxCommand) {
        $shownUrl = $shownUrl.Substring(0, $maxCommand) + " ...[truncated, $($url.Length) characters]"
    }

    $material = @(
        $Tool, $Class, $ConversationId, $TurnId,
        $command.Trim(), $workingDirectory.Trim(),
        $url.Trim(), $targetHost.Trim(),
        $action.Trim(), $control.Trim(), $filePath.Trim(), $fieldMaterial, $executionMaterial
    ) -join [char]31
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $digest = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($material)) }
    finally { $sha.Dispose() }
    $fingerprint = -join ($digest | ForEach-Object { $_.ToString('x2') })

    $risk = switch ($Class) {
        'Terminal' {
            if ($execution.mode -eq 'isolated') {
                'Isolated Terminal command. Only the selected Project is mounted; other Tools are not isolated. Check Project access, network and environment grants.'
            }
            else { 'This runs a command on your computer with your account. It can read, change or delete files, and it can reach the network.' }
        }
        'FileWrite' { 'This writes to a file outside the project folder, where DeskPilot cannot undo it for you.' }
        'Mcp' { 'This calls an attached tool that may change something outside DeskPilot.' }
        'BrowserNavigation' { 'This opens an address outside the site this task started on. Check the whole address, including anything after the question mark - that is where a page tries to send information it should not have.' }
        'BrowserAction' {
            switch ($action) {
                'upload_file' { 'This sends a file from your computer to the website. Check the file and the site: once it is sent, DeskPilot cannot take it back.' }
                'download_file' { 'This saves a file from the website onto your computer. DeskPilot puts it in a holding folder and never opens or runs it.' }
                'click_button' { 'This presses a control on the page. It may send, change, buy or delete something on that site, and DeskPilot cannot undo it.' }
                default { 'This types these values into the page and may send them. Check every value: whatever is here leaves your computer.' }
            }
        }
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
            url              = $shownUrl
            host             = $targetHost
            action           = $action
            control          = $control
            filePath         = $filePath
            fields           = $fields
            execution        = if ($Class -eq 'Terminal') { $execution } else { $null }
        }
        risk           = $risk
        requestedUtc   = [datetime]::UtcNow.ToString('o')
    }
}
