function Restore-DpIntercomCheckpoint {
    <#
    .SYNOPSIS
        Runs the /undo command: takes the phone's Conversation back to before its
        last prompt.
    .DESCRIPTION
        The remote half of a Checkpoint restore. Finds the most recent user Message
        carrying a Checkpoint in the Conversation Intercom is working in, and either
        describes what would be discarded or performs it.

        It takes two messages. A phone is where a mistyped command is most likely,
        and this is the only Intercom command that rewrites files on disk - so the
        first `/undo` only reports, and `/undo confirm` acts. The same two-step
        shape as `/delete`.

        The bound Conversation is authoritative: if it has gone, that is an error
        rather than an invitation to undo work somewhere the operator never chose.
    .PARAMETER Confirmed
        Perform the restore. Without it, report what would happen and stop.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Confirmation is the two-step /undo grammar; ShouldProcess cannot prompt over Telegram.')]
    param(
        [switch]$Confirmed
    )

    $state = $script:DeskPilot
    $intercom = $state.Intercom

    if ($state.TurnRunning) {
        $null = Send-DpIntercomMessage -Title 'A job is running.' -Line @('Send /stop first, then /undo.') -Kind 'notice'
        return
    }

    $conversation = $null
    if ($intercom.ConversationId) {
        $conversation = $state.Conversations[$intercom.ConversationId]
        if (-not $conversation) {
            $intercom.ConversationId = $null
            $null = Send-DpIntercomMessage -Title 'I did not undo anything.' -Line @(
                'The conversation we were working in no longer exists.',
                'Send /chats to pick another.'
            ) -Kind 'refused'
            return
        }
    }
    if (-not $conversation) {
        $conversation = @($state.Conversations.Values) |
            Where-Object { -not [bool](Get-DpPropertyValue -InputObject $_ -Name @('archived') -Default $false) } |
            Sort-Object -Property updatedUtc -Descending |
            Select-Object -First 1
    }
    if (-not $conversation) {
        $null = Send-DpIntercomMessage -Title 'There is nothing to undo.' -Line @('No conversation has run yet.') -Kind 'notice'
        return
    }

    $writable = Test-DpConversationWritable -Conversation $conversation
    if (-not $writable.ok) {
        $null = Send-DpIntercomMessage -Title 'I did not undo anything.' -Line @(
            $writable.reason,
            'Send /chats to pick another.'
        ) -Kind 'refused'
        return
    }

    # The last prompt that has a Checkpoint, which is the one /undo means.
    $messages = @($conversation.messages)
    $target = $null
    for ($i = $messages.Count - 1; $i -ge 0; $i--) {
        if ([string]$messages[$i].role -ne 'user') { continue }
        $checkpoint = Get-DpPropertyValue -InputObject $messages[$i] -Name @('checkpoint') -Default $null
        $sha = [string](Get-DpPropertyValue -InputObject $checkpoint -Name @('sha') -Default '')
        if ($sha) { $target = $messages[$i]; break }
    }
    if (-not $target) {
        $null = Send-DpIntercomMessage -Title 'There is nothing to undo here.' -Line @(
            'No message in this conversation has a checkpoint.',
            'Checkpoints are recorded from the turn after this feature was installed, and only while a project is open.'
        ) -Kind 'notice'
        return
    }

    $restoreParams = @{
        Conversation = $conversation
        MessageId    = [string]$target.id
        Root         = [string]$state.Settings.workspaceFolder
    }

    if (-not $Confirmed) {
        $preview = Restore-DpCheckpoint @restoreParams -Preview
        if (-not $preview.ok) {
            $null = Send-DpIntercomMessage -Title 'I cannot undo that.' -Line @($preview.error) -Kind 'refused'
            return
        }
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add("Your prompt: $($preview.prompt)")
        $lines.Add("This drops $($preview.messagesDropped) message(s) from '$([string]$conversation.title)'.")
        if ($preview.filesTried) {
            $lines.Add("It also puts back $(@($preview.files).Count) file(s) DeskPilot changed. Anything you edited yourself is left alone.")
        }
        else {
            $lines.Add('No files were changed, so only the conversation is affected.')
        }
        $lines.Add('Send /undo confirm to go ahead. This cannot be undone.')
        $null = Send-DpIntercomMessage -Title 'This cannot be undone.' -Line @($lines.ToArray()) -Kind 'notice'
        return
    }

    $restore = Restore-DpCheckpoint @restoreParams
    if (-not $restore.ok) {
        $null = Send-DpIntercomMessage -Title 'I could not undo that.' -Line @($restore.error) -Kind 'refused'
        return
    }

    if ($state.DataDir) {
        Save-DpConversationStore -Store $state.Conversations -Directory $state.DataDir
        Save-DpChangeStore -Store $state.Changes -Directory $state.DataDir
    }
    $state.ConversationsRevision = [int]$state.ConversationsRevision + 1

    $touched = @($restore.restored).Count + @($restore.removed).Count
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add($(if ($touched -gt 0) { "Put back $touched file(s)." } else { 'No files needed changing.' }))
    # Repeating the prompt is what makes this actionable from a phone: the operator
    # can copy it, reword it, and send it straight back.
    if ($restore.prompt) {
        $lines.Add('Your prompt was:')
        $lines.Add([string]$restore.prompt)
        $lines.Add('Send it again, reworded, whenever you are ready.')
    }
    $null = Send-DpIntercomMessage -Title 'Undone.' -Line @($lines.ToArray()) -Kind 'undo'
}
