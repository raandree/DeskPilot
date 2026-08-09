function ConvertFrom-DpIntercomUpdate {
    <#
    .SYNOPSIS
        Normalizes one Telegram update into an Intercom command.
    .DESCRIPTION
        Turns a raw Telegram update object into a bounded, validated command
        record the pump can act on. This is the trust boundary: the allow-list is
        applied here, before any text is interpreted, so an update from any other
        chat becomes a 'rejected' record and its content is never parsed as a
        command.

        Recognised kinds:
          answer   - a reply to the message that carried the pending question
          prompt   - plain text to run as a prompt
          stop     - /stop
          steer    - /steer <text>: cancel the running Turn, then run <text>
          status   - /status
          chats    - /chats: list the conversations that can be switched to
          chat     - /chat <n>: switch to one of them
          archive  - /archive <n>: hide one from the list
          delete   - /delete <n> [confirm]: remove one for good
          new      - /new [text]: start a fresh conversation, optionally with work
          help     - /help
          rejected - the chat is not allow-listed
          ignore   - nothing actionable (an edit, a photo, an empty message)
    .PARAMETER Update
        One element of the Telegram getUpdates result array.
    .PARAMETER AllowedChatId
        The single allow-listed chat id. An empty value rejects everything.
    .PARAMETER PendingQuestionMessageId
        The Telegram message id the pending question was sent as, or 0 when no
        question is waiting. A reply to this id is the only accepted answer.
    .PARAMETER MaxTextLength
        The bound applied to any text carried out of this function.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Update,

        [AllowNull()]
        [string]$AllowedChatId,

        [long]$PendingQuestionMessageId = 0,

        [ValidateRange(16, 100000)]
        [int]$MaxTextLength = 4000
    )

    $result = @{
        updateId         = 0
        kind             = 'ignore'
        text             = ''
        chatId           = ''
        messageId        = 0
        replyToMessageId = 0
        reason           = ''
        # Display-only, and populated even for a rejected chat so the pairing
        # flow can show the operator who is trying to reach the bot. Never
        # interpreted: 'text' stays empty unless the chat is allow-listed.
        fromName         = ''
        preview          = ''
    }

    if ($null -eq $Update) {
        $result.reason = 'Empty update.'
        return $result
    }

    $result.updateId = [long](Get-DpPropertyValue -InputObject $Update -Name @('update_id') -Default 0)

    $message = Get-DpPropertyValue -InputObject $Update -Name @('message') -Default $null
    if ($null -eq $message) {
        $result.reason = 'No message (edits, channel posts and callbacks are ignored).'
        return $result
    }

    $chat = Get-DpPropertyValue -InputObject $message -Name @('chat') -Default $null
    $result.chatId = [string](Get-DpPropertyValue -InputObject $chat -Name @('id') -Default '')
    $result.messageId = [long](Get-DpPropertyValue -InputObject $message -Name @('message_id') -Default 0)

    $from = Get-DpPropertyValue -InputObject $message -Name @('from') -Default $null
    $firstName = [string](Get-DpPropertyValue -InputObject $from -Name @('first_name') -Default '')
    $userName = [string](Get-DpPropertyValue -InputObject $from -Name @('username') -Default '')
    $displayName = (@($firstName, $(if ($userName) { "@$userName" })) | Where-Object { $_ }) -join ' '
    if ($displayName.Length -gt 60) { $displayName = $displayName.Substring(0, 60) }
    $result.fromName = $displayName

    $preview = ([string](Get-DpPropertyValue -InputObject $message -Name @('text') -Default '')).Trim()
    if ($preview.Length -gt 60) { $preview = $preview.Substring(0, 60) + '...' }
    $result.preview = $preview

    # The allow-list runs before the text is read. An update from any other chat
    # is recorded and dropped; its content never reaches command parsing.
    if ([string]::IsNullOrWhiteSpace($AllowedChatId) -or $result.chatId -ne $AllowedChatId.Trim()) {
        $result.kind = 'rejected'
        $result.reason = "Message from chat '$($result.chatId)' is not allow-listed."
        return $result
    }

    $rawText = [string](Get-DpPropertyValue -InputObject $message -Name @('text') -Default '')
    if ([string]::IsNullOrWhiteSpace($rawText)) {
        $result.reason = 'Message carried no text.'
        return $result
    }

    $text = $rawText.Trim()
    if ($text.Length -gt $MaxTextLength) { $text = $text.Substring(0, $MaxTextLength) }

    $replyTo = Get-DpPropertyValue -InputObject $message -Name @('reply_to_message') -Default $null
    if ($replyTo) {
        $result.replyToMessageId = [long](Get-DpPropertyValue -InputObject $replyTo -Name @('message_id') -Default 0)
    }

    if (-not $text.StartsWith('/')) {
        # A reply to the message that carried the pending question is the answer;
        # the nonce is the message id, so there is nothing for the user to type.
        if ($PendingQuestionMessageId -gt 0 -and $result.replyToMessageId -eq $PendingQuestionMessageId) {
            $result.kind = 'answer'
        }
        else {
            $result.kind = 'prompt'
        }
        $result.text = $text
        return $result
    }

    # /command@BotName is what Telegram sends in groups; strip the mention.
    $split = $text.Substring(1) -split '\s+', 2
    $verb = ($split[0] -split '@', 2)[0].ToLowerInvariant()
    $argument = if ($split.Count -gt 1) { $split[1].Trim() } else { '' }

    switch ($verb) {
        'stop' { $result.kind = 'stop' }
        'status' { $result.kind = 'status' }
        'help' { $result.kind = 'help' }
        'start' { $result.kind = 'help' }
        'chats' { $result.kind = 'chats' }
        'chat' {
            $result.kind = 'chat'
            $result.text = $argument
        }
        'archive' {
            $result.kind = 'archive'
            $result.text = $argument
        }
        'delete' {
            $result.kind = 'delete'
            $result.text = $argument
        }
        'new' {
            $result.kind = 'new'
            $result.text = $argument
        }
        'steer' {
            $result.kind = 'steer'
            $result.text = $argument
        }
        default {
            $result.kind = 'ignore'
            $result.reason = "Unknown command '/$verb'. Send /help for the list."
        }
    }

    $result
}
