function Copy-DpConversation {
    <#
    .SYNOPSIS
        Duplicates a Conversation into a brand-new, detached Conversation record.
    .DESCRIPTION
        Deep-copies the source Conversation''s Messages and history (via a JSON
        round-trip so the copy shares no object references with the original),
        assigns a fresh id and timestamps, and prefixes the title. The copy is
        never pinned/archived/unread and its title is locked so auto-titling
        never renames it. The copied Conversation carries over the Model and
        colour but is otherwise independent of the source.
    .PARAMETER Conversation
        The source Conversation hashtable to duplicate.
    .PARAMETER TitlePrefix
        Text placed in front of the source title; defaults to ''Copy of ''.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Conversation,

        [string]$TitlePrefix = 'Copy of '
    )

    $now = [DateTime]::UtcNow.ToString('o')

    $messages = [System.Collections.Generic.List[object]]::new()
    foreach ($message in @($Conversation.messages)) {
        if ($null -eq $message) { continue }
        $messages.Add(($message | ConvertTo-Json -Depth 20 -Compress | ConvertFrom-Json))
    }

    $history = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in @($Conversation.history)) {
        if ($null -eq $entry) { continue }
        $history.Add(($entry | ConvertTo-Json -Depth 20 -Compress | ConvertFrom-Json))
    }

    $baseTitle = if ($Conversation.title) { [string]$Conversation.title } else { 'Conversation' }

    @{
        id          = New-DpId -Prefix 'c'
        title       = $TitlePrefix + $baseTitle
        titleLocked = $true
        model       = $Conversation.model
        pinned      = $false
        archived    = $false
        unread      = $false
        color       = $Conversation.color
        compactedUtc = $null
        createdUtc  = $now
        updatedUtc  = $now
        messages    = $messages
        history     = $history
    }
}
