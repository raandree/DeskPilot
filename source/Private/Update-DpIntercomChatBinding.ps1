function Update-DpIntercomChatBinding {
    <#
    .SYNOPSIS
        Settles Intercom's state after the conversation list changes.
    .DESCRIPTION
        Persists the store, drops the stale listing numbers, and - when the
        Conversation Intercom was pointing at is no longer usable - rebinds to the
        most recent survivor.

        Without the rebind the next instruction from the phone would land in a
        Conversation the operator just archived or deleted.
    .PARAMETER ConversationId
        The Conversation that was archived, unarchived or deleted.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Settles in-process state on the accept thread after an already-confirmed action; a prompt there would hang the Host Server.')]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ConversationId
    )

    $state = $script:DeskPilot
    $intercom = $state.Intercom

    # The numbers the operator was last shown no longer describe the list.
    $intercom.ChatIndex = @()

    if ([string]$intercom.ConversationId -eq $ConversationId) {
        $bound = $state.Conversations[$ConversationId]
        if (-not (Test-DpConversationWritable -Conversation $bound).ok) {
            $intercom.ConversationId = [string](@(Get-DpIntercomChatList -MaxItems 1) | Select-Object -First 1 -ExpandProperty id)
        }
    }

    if ($state.DataDir) { Save-DpConversationStore -Store $state.Conversations -Directory $state.DataDir }

    # The window did not ask for this, so tell it something changed.
    $state.ConversationsRevision = [int]$state.ConversationsRevision + 1
}
