function Send-DpIntercomApproval {
    <#
    .SYNOPSIS
        Forwards a pending Terminal approval to the phone.
    .DESCRIPTION
        Called from the Turn loop the moment the approval card is published to the
        browser, so the operator who is away is not the last to know. Either
        surface can answer; the bridge accepts the first one and the other is told
        the request has moved on.

        The command is sent in full and verbatim. It is the one thing the operator
        has to look at, and a truncated or paraphrased command would be an
        approval of something other than what runs - the trailing argument is
        usually where the danger is. Nothing else about the request travels: the
        model's own account of why it wants this is not sent, because the model is
        the party being checked and its reasons are attacker-reachable text.

        Group chats are refused outright. An approval in a group is a request that
        anyone in that group can grant, and the switch that would allow it is a
        deliberate separate decision, defaulted off.
    .PARAMETER RequestId
        The bridge's request id, matched when the decision is submitted.
    .PARAMETER ConversationId
        The Conversation the request belongs to.
    .PARAMETER Request
        The approval request from New-DpApprovalRequest.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$RequestId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ConversationId,

        [Parameter(Mandatory)]
        [object]$Request
    )

    $state = $script:DeskPilot
    $intercom = $state.Intercom
    if (-not $intercom -or -not $intercom.Running) { return }
    if (-not (Test-DpIntercomProject -Settings $state.Settings).allowed) { return }

    $chatId = [string](Get-DpPropertyValue -InputObject $intercom -Name @('ReplyChatId') -Default '')
    if (-not $chatId) { $chatId = [string]$state.Settings.intercom.chatId }

    # A group can only be answered when the operator has turned that on for
    # approvals, separately from group access to Intercom itself.
    $chat = Test-DpIntercomChat -ChatId $chatId -Settings $state.Settings
    if ($chat.group -and -not $state.Settings.intercom.groupApproval) {
        Add-DpIntercomLog -Direction 'out' -Kind 'approval-group-blocked' -Detail 'An approval was not sent: this chat is a group and group approval is off.'
        return
    }

    $token = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $intercom.PendingApproval = @{
        id             = $RequestId
        conversationId = $ConversationId
        chatId         = $chatId
        token          = $token
        askedUtc       = [DateTime]::UtcNow
    }

    $summary = Get-DpPropertyValue -InputObject $Request -Name @('summary') -Default $null
    $command = [string](Get-DpPropertyValue -InputObject $summary -Name @('command') -Default '')
    $directory = [string](Get-DpPropertyValue -InputObject $summary -Name @('workingDirectory') -Default '')
    $project = [string](Get-DpPropertyValue -InputObject $summary -Name @('project') -Default '')

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add([string](Get-DpPropertyValue -InputObject $Request -Name @('risk') -Default 'This runs on your computer.'))
    if ($project) { $lines.Add("Project: $project") }
    if ($directory) { $lines.Add("In: $directory") }
    $execution = Get-DpPropertyValue -InputObject $summary -Name 'execution'
    if ($execution) {
        $lines.Add("Terminal: $($execution.mode)")
        if ($execution.mode -eq 'isolated') {
            $lines.Add("Project access: $($execution.projectAccess); network: $($execution.network)")
            $lines.Add("HTTPS origins: $(@($execution.allowedHosts) -join ', ')")
            $variables = @($execution.environment | ForEach-Object { "$($_.name)$(if ($_.secret) { ' [secret]' })" })
            $lines.Add("Environment: $($variables -join ', ')")
            $lines.Add("Limits: $($execution.timeoutSeconds)s; $($execution.cpuCount) CPU; $($execution.memoryMB) MiB; $($execution.processLimit) processes; $($execution.outputBytes) output bytes; $($execution.tempMB) MiB temporary storage")
        }
    }

    $keyboard = Get-DpIntercomKeyboard -Choice @(
        @{ label = 'Run it'; data = "a|$token|y" }
        @{ label = 'No'; data = "a|$token|n" }
    )

    $sendParams = @{
        Title    = 'The agent wants to run a command'
        Line     = @($lines.ToArray())
        Kind     = 'approval'
        Capture  = 'approval'
        Body     = $command
        Keyboard = $keyboard
    }
    if (-not $keyboard) { $sendParams.Remove('Keyboard') }

    $null = Send-DpIntercomMessage @sendParams
}
