function Set-DpIntercomChatRemoved {
    <#
    .SYNOPSIS
        Settles Intercom's state after a Conversation is archived or deleted.
    .DESCRIPTION
        Persists the store, drops the stale listing numbers, and - when the
        Conversation that just went away was the one Intercom was pointing at -
        rebinds to the most recent survivor.

        Without the rebind the next instruction from the phone would land in a
        Conversation the operator just removed, or create a new one silently.
    .PARAMETER ConversationId
        The Conversation that was archived or deleted.
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
        $intercom.ConversationId = [string](@(Get-DpIntercomChatList -MaxItems 1) | Select-Object -First 1 -ExpandProperty id)
    }

    if ($state.DataDir) { Save-DpConversationStore -Store $state.Conversations -Directory $state.DataDir }
}
