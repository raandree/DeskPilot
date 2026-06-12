function Reset-DpConversationForRerun {
    <#
    .SYNOPSIS
        Truncates a Conversation to just before a user Message so a Turn can re-run.
    .DESCRIPTION
        Finds the Message with id FromMessageId; it must be a user Message. Drops
        that Message and every Message after it from the Conversation's `messages`,
        then rebuilds the Engine `history` ({ role, content }) from the surviving
        Messages so a replayed Turn sees the correct prior context. Returns the
        text of the removed user Message (the prompt to re-send, used by Regenerate;
        Edit ignores it and sends new text instead). Returns $null when the id is
        not found or does not name a user Message, so the caller can reply 400.
        Mutates the passed Conversation in place; it does not persist - the caller's
        Turn run persists on success, so a failed re-run never corrupts the on-disk
        store.
    .PARAMETER Conversation
        The Conversation hashtable to truncate.
    .PARAMETER FromMessageId
        The id of the user Message to re-run from (inclusive: it and all later
        Messages are removed).
    .OUTPUTS
        System.String (the removed user prompt) or $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Conversation,

        [Parameter(Mandatory)]
        [string]$FromMessageId
    )

    $messages = @($Conversation.messages)
    $index = -1
    for ($i = 0; $i -lt $messages.Count; $i++) {
        if ([string]$messages[$i].id -eq $FromMessageId) { $index = $i; break }
    }
    if ($index -lt 0) { return $null }
    if ([string]$messages[$index].role -ne 'user') { return $null }

    $prompt = [string]$messages[$index].text
    $kept = if ($index -eq 0) { @() } else { $messages[0..($index - 1)] }

    $newMessages = [System.Collections.Generic.List[object]]::new()
    foreach ($message in $kept) { $newMessages.Add($message) }
    $Conversation.messages = $newMessages

    $newHistory = [System.Collections.Generic.List[object]]::new()
    foreach ($message in $kept) {
        $role = [string]$message.role
        $text = [string]$message.text
        if (-not [string]::IsNullOrWhiteSpace($role)) {
            $newHistory.Add(@{ role = $role; content = $text })
        }
    }
    $Conversation.history = $newHistory

    $prompt
}

