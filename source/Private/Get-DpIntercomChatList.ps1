function Get-DpIntercomChatList {
    <#
    .SYNOPSIS
        Lists the Conversations Intercom can switch between.
    .DESCRIPTION
        Returns the most recently used non-archived Conversations, newest first,
        each with the number the operator types to select it.

        The numbering is a snapshot, not a property of the Conversation: the order
        is by last activity, so running a Turn reorders the list. The caller stores
        the ids this produced (Intercom.ChatIndex) and resolves a later "/chat 3"
        against that snapshot, so the number the operator saw is the Conversation
        they get - even if the order has since changed.
    .PARAMETER MaxItems
        How many Conversations to offer. A phone list nobody scrolls is worse than
        a short one.
    .PARAMETER IncludeArchived
        Also list archived Conversations, marked as such. Off by default: the
        archived ones are the ones the operator has already finished with, and
        they are only wanted when something needs bringing back.
    .OUTPUTS
        System.Collections.Hashtable[]
    #>
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param(
        [ValidateRange(1, 50)]
        [int]$MaxItems = 10,

        [switch]$IncludeArchived
    )

    $state = $script:DeskPilot
    $boundId = [string]$state.Intercom.ConversationId

    $ordered = @($state.Conversations.Values) |
        Where-Object { $IncludeArchived -or -not [bool](Get-DpPropertyValue -InputObject $_ -Name @('archived') -Default $false) } |
        Sort-Object -Property @{ Expression = { [string](Get-DpPropertyValue -InputObject $_ -Name @('updatedUtc') -Default '') } } -Descending |
        Select-Object -First $MaxItems

    $number = 0
    foreach ($conversation in $ordered) {
        $number++
        $title = [string](Get-DpPropertyValue -InputObject $conversation -Name @('title') -Default 'Untitled')
        if ($title.Length -gt 60) { $title = $title.Substring(0, 60) + '...' }
        @{
            number   = $number
            id       = [string]$conversation.id
            title    = $title
            current  = ([string]$conversation.id -eq $boundId)
            archived = [bool](Get-DpPropertyValue -InputObject $conversation -Name @('archived') -Default $false)
            updated  = [string](Get-DpPropertyValue -InputObject $conversation -Name @('updatedUtc') -Default '')
        }
    }
}
