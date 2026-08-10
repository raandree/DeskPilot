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
          chats    - /chats [all]: list the conversations that can be switched to
          chat     - /chat <n>: switch to one of them
          agents   - /agents: list the agents that can be switched to
          agent    - /agent <n|none>: switch to one of them, or clear the selection
          projects - /projects: list the registered projects
          project  - /project <n|new <path>>: switch to one, or register a folder
          archive  - /archive <n>: hide one from the list
          unarchive - /unarchive <n>: bring an archived one back
          delete   - /delete <n> [confirm]: remove one for good
          new      - /new [text]: start a fresh conversation, optionally with work
          help     - /help
          edited   - the operator edited an earlier message; acknowledged, never run
          rejected - the chat is not allow-listed
          ignore   - nothing actionable (a photo, a channel post, an empty message)
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
        # A file the operator sent, to be downloaded before the prompt runs.
        attachment       = $null
        # The tap on an inline-keyboard button that produced this, answered so
        # Telegram stops showing the button as loading.
        callbackId       = ''
    }

    if ($null -eq $Update) {
        $result.reason = 'Empty update.'
        return $result
    }

    $result.updateId = [long](Get-DpPropertyValue -InputObject $Update -Name @('update_id') -Default 0)

    # A tapped button is not a message: it carries its own id, which must be
    # answered or Telegram leaves the button spinning, and its data is a token this
    # bot minted rather than anything the operator typed.
    $callback = Get-DpPropertyValue -InputObject $Update -Name @('callback_query') -Default $null
    if ($callback) {
        $result.callbackId = [string](Get-DpPropertyValue -InputObject $callback -Name @('id') -Default '')
        $callbackMessage = Get-DpPropertyValue -InputObject $callback -Name @('message') -Default $null
        $callbackChat = Get-DpPropertyValue -InputObject $callbackMessage -Name @('chat') -Default $null
        $result.chatId = [string](Get-DpPropertyValue -InputObject $callbackChat -Name @('id') -Default '')
        $result.messageId = [long](Get-DpPropertyValue -InputObject $callbackMessage -Name @('message_id') -Default 0)

        $callbackFrom = Get-DpPropertyValue -InputObject $callback -Name @('from') -Default $null
        $callbackFirst = [string](Get-DpPropertyValue -InputObject $callbackFrom -Name @('first_name') -Default '')
        $callbackUser = [string](Get-DpPropertyValue -InputObject $callbackFrom -Name @('username') -Default '')
        $callbackName = (@($callbackFirst, $(if ($callbackUser) { "@$callbackUser" })) | Where-Object { $_ }) -join ' '
        if ($callbackName.Length -gt 60) { $callbackName = $callbackName.Substring(0, 60) }
        $result.fromName = $callbackName

        # The allow-list runs before the data is read, exactly as it does for a
        # message: a tap from any other chat is recorded and dropped.
        if ([string]::IsNullOrWhiteSpace($AllowedChatId) -or $result.chatId -ne $AllowedChatId.Trim()) {
            $result.kind = 'rejected'
            $result.reason = "Button tap from chat '$($result.chatId)' is not allow-listed."
            return $result
        }

        $data = [string](Get-DpPropertyValue -InputObject $callback -Name @('data') -Default '')
        if ($data.Length -gt 64) { $data = $data.Substring(0, 64) }
        $result.kind = 'callback'
        $result.text = $data
        $result.preview = $data
        return $result
    }

    $message = Get-DpPropertyValue -InputObject $Update -Name @('message') -Default $null
    $isEdit = $false
    if ($null -eq $message) {
        $message = Get-DpPropertyValue -InputObject $Update -Name @('edited_message') -Default $null
        $isEdit = $null -ne $message
    }
    if ($null -eq $message) {
        $result.reason = 'No message (channel posts and callbacks are ignored).'
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

    # A file message carries no 'text' at all - the words are in 'caption' - so
    # reading only 'text' made an attachment vanish without a reply.
    $attachment = Get-DpIntercomAttachmentRef -Message $message
    if ($attachment) {
        $rawText = [string](Get-DpPropertyValue -InputObject $message -Name @('caption') -Default '')
        $result.preview = $(if ($rawText) { $rawText } else { [string]$attachment.fileName })
    }

    if ([string]::IsNullOrWhiteSpace($rawText) -and -not $attachment) {
        $result.reason = 'Message carried no text.'
        return $result
    }

    # Editing a message is a natural way to fix a typed command on a phone, but it
    # is never executed: Telegram delivers an edit as a fresh update, so acting on
    # one would silently re-run a command that already ran - with different text,
    # and potentially hours later. It is acknowledged instead, so the operator
    # learns their correction did not land rather than waiting for a reply that
    # never comes.
    if ($isEdit) {
        $result.kind = 'edited'
        $result.reason = 'An edited message is not run.'
        return $result
    }

    $text = $rawText.Trim()
    if ($text.Length -gt $MaxTextLength) { $text = $text.Substring(0, $MaxTextLength) }

    $replyTo = Get-DpPropertyValue -InputObject $message -Name @('reply_to_message') -Default $null
    if ($replyTo) {
        $result.replyToMessageId = [long](Get-DpPropertyValue -InputObject $replyTo -Name @('message_id') -Default 0)
    }

    # A file is always work to do, never a command: a caption beginning with a
    # slash is far more likely to be a filename than an instruction.
    if ($attachment) {
        $result.kind = 'prompt'
        $result.text = $text
        $result.attachment = $attachment
        return $result
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
        'chats' {
            $result.kind = 'chats'
            $result.text = $argument
        }
        'chat' {
            $result.kind = 'chat'
            $result.text = $argument
        }
        'agents' { $result.kind = 'agents' }
        'agent' {
            $result.kind = 'agent'
            $result.text = $argument
        }
        'projects' { $result.kind = 'projects' }
        'project' {
            $result.kind = 'project'
            $result.text = $argument
        }
        'archive' {
            $result.kind = 'archive'
            $result.text = $argument
        }
        'unarchive' {
            $result.kind = 'unarchive'
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
        'undo' {
            $result.kind = 'undo'
            $result.text = $argument
        }
        default {
            $result.kind = 'ignore'
            $result.reason = "Unknown command '/$verb'. Send /help for the list."
        }
    }

    $result
}
