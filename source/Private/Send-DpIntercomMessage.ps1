function Send-DpIntercomMessage {
    <#
    .SYNOPSIS
        Queues an outbound Intercom message.
    .DESCRIPTION
        Composes the text from structured parts, splits it to Telegram's message
        limit, and appends the parts to the outbound queue. The pump drains the
        queue one message at a time so ordering is preserved and the accept thread
        never waits on the network.

        The rolling hourly cap is applied here, so a runaway loop or a flood is
        dropped and counted rather than queued forever. The live status message is
        exempt: it is an edit of one existing message, produces no notification,
        and is the mechanism the operator uses to detect a dead machine.

        Each message is addressed to the chat the interaction it belongs to came
        from, so an answer to something asked in the shared group lands in the
        group rather than privately. The live status message is the exception:
        there is exactly one of it, edited in place, and it belongs to the
        operator's own chat.

        That target is re-validated against the live allow-list here, at the
        moment of sending. The ambient reply target is set by the pump before a
        command is classified and outlives a single tick in three different
        carriers, so "never answer a caller you just rejected" cannot rest on any
        one early return upstream. A target that no longer passes is recorded and
        the message falls back to the operator's own chat - the content still
        reaches them, just never the chat that lost its authority.
    .PARAMETER Title
        The first line of the message.
    .PARAMETER Line
        Short fact lines under the title.
    .PARAMETER Body
        Optional long text.
    .PARAMETER Kind
        The message kind, recorded in the audit log.
    .PARAMETER Capture
        'question' to remember the sent message id as the answer nonce, 'status'
        to remember it as the live status message.
    .OUTPUTS
        System.Boolean - whether the message was queued.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Title,

        [AllowEmptyCollection()]
        [string[]]$Line = @(),

        [AllowNull()]
        [string]$Body,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Kind,

        [ValidateSet('', 'question', 'status')]
        [string]$Capture = '',

        [AllowNull()]
        [hashtable]$Keyboard
    )

    $intercom = $script:DeskPilot.Intercom
    if (-not $intercom) { return $false }

    $isStatus = $Capture -eq 'status'

    # Optional by design: no reply target means the operator's own chat, which is
    # also where DeskPilot speaks on its own initiative.
    $replyChat = [string](Get-DpPropertyValue -InputObject $intercom -Name @('ReplyChatId') -Default '')

    $target = [string]$script:DeskPilot.Settings.intercom.chatId
    if (-not $isStatus -and -not [string]::IsNullOrWhiteSpace($replyChat)) {
        # Re-checked against the allow-list as it stands now, not as it stood when
        # the work was accepted. A group switched off mid-Turn, or a routing field
        # nobody remembered to clear, ends here rather than in a de-authorised chat.
        if ((Test-DpIntercomChat -ChatId $replyChat).allowed) {
            $target = $replyChat
        }
        else {
            $intercom.Counters.dropped++
            Add-DpIntercomLog -Direction 'out' -Kind 'misrouted' -ChatId $replyChat -Accepted $false `
                -Detail "A '$Kind' message was addressed to chat '$replyChat', which is no longer allow-listed. Sent to your own chat instead."
        }
    }

    # There is nowhere to send to during pairing, when the operator has not yet
    # confirmed which chat is theirs. Queuing would only build a backlog that
    # arrives all at once the moment they do.
    if ([string]::IsNullOrWhiteSpace($target)) { return $false }

    if (-not $isStatus) {
        $cap = 60
        if ($script:DeskPilot.Settings.intercom) { $cap = [int]$script:DeskPilot.Settings.intercom.maxMessagesPerHour }
        if ($cap -lt 1) { $cap = 1 }

        $cutoff = [DateTime]::UtcNow.AddHours(-1)
        for ($index = $intercom.RateWindow.Count - 1; $index -ge 0; $index--) {
            if ($intercom.RateWindow[$index] -lt $cutoff) { $intercom.RateWindow.RemoveAt($index) }
        }
        if ($intercom.RateWindow.Count -ge $cap) {
            $intercom.Counters.dropped++
            Add-DpIntercomLog -Direction 'out' -Kind 'rate-limited' -Detail "Dropped a '$Kind' message: more than $cap messages in the last hour." -Accepted $false
            return $false
        }
        $intercom.RateWindow.Add([DateTime]::UtcNow)
    }

    $formatParams = @{ Title = $Title; Line = $Line }
    if (-not [string]::IsNullOrWhiteSpace($Body)) { $formatParams.Body = $Body }
    $parts = @(Format-DpIntercomMessage @formatParams)

    # Only the first part can carry the nonce, and a status message is never split.
    # The keyboard rides with it for the same reason: buttons belong to one message,
    # and the first is the one the nonce identifies.
    $partIndex = 0
    foreach ($part in $parts) {
        $intercom.Outbound.Enqueue(@{
                kind      = $Kind
                text      = $part
                chatId    = $target
                capture   = $(if ($partIndex -eq 0) { $Capture } else { '' })
                edit      = $isStatus
                plainOnly = $false
                keyboard  = $(if ($partIndex -eq 0) { $Keyboard } else { $null })
            })
        $partIndex++
    }

    $true
}
