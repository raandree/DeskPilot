function New-DpConversation {
    <#
    .SYNOPSIS
        Creates a new in-memory Conversation record.
    .PARAMETER Title
        Optional initial title; defaults to 'New conversation'.
    .PARAMETER Model
        Optional Model id pinned to this Conversation.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$Title = 'New conversation',
        [string]$Model
    )
    $now = [DateTime]::UtcNow.ToString('o')
    @{
        id          = New-DpId -Prefix 'c'
        title       = $Title
        titleLocked = $false
        model       = $Model
        pinned      = $false
        archived    = $false
        unread      = $false
        color       = $null
        createdUtc  = $now
        updatedUtc  = $now
        messages    = [System.Collections.Generic.List[object]]::new()
        history     = [System.Collections.Generic.List[object]]::new()
    }
}
