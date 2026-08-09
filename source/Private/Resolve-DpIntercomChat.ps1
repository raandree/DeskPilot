function Resolve-DpIntercomChat {
    <#
    .SYNOPSIS
        Resolves the number an operator typed into a Conversation.
    .DESCRIPTION
        Shared by /chat, /archive and /delete. Resolves against the numbering the
        last /chats listing actually showed (Intercom.ChatIndex), falling back to
        the current order when the operator never asked for a list.

        That indirection is the point: the list is ordered by last activity, so a
        Turn finishing between "/chats" and "/delete 3" would silently renumber it
        - and for a delete, acting on a different Conversation than the one shown
        would be unrecoverable.
    .PARAMETER Number
        The 1-based number from the listing.
    .OUTPUTS
        System.Collections.Hashtable with ok, conversation and message.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [int]$Number
    )

    $state = $script:DeskPilot
    if ($Number -lt 1) {
        return @{ ok = $false; conversation = $null; message = 'Send /chats to see the list, then use the number beside it.' }
    }

    $index = @($state.Intercom.ChatIndex)
    $conversationId = if ($Number -le $index.Count) {
        [string]$index[$Number - 1]
    }
    else {
        [string](@(Get-DpIntercomChatList) | Where-Object { $_.number -eq $Number } | Select-Object -First 1 -ExpandProperty id)
    }

    $conversation = if ($conversationId) { $state.Conversations[$conversationId] } else { $null }
    if (-not $conversation) {
        return @{ ok = $false; conversation = $null; message = "There is no conversation $Number. Send /chats to see the list." }
    }

    @{ ok = $true; conversation = $conversation; message = '' }
}
