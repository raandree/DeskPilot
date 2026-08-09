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
        [string]$Capture = ''
    )

    $intercom = $script:DeskPilot.Intercom
    if (-not $intercom) { return $false }

    # There is nowhere to send to during pairing, when the operator has not yet
    # confirmed which chat is theirs. Queuing would only build a backlog that
    # arrives all at once the moment they do.
    if ([string]::IsNullOrWhiteSpace([string]$script:DeskPilot.Settings.intercom.chatId)) { return $false }

    $isStatus = $Capture -eq 'status'

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
    $partIndex = 0
    foreach ($part in $parts) {
        $intercom.Outbound.Enqueue(@{
                kind      = $Kind
                text      = $part
                capture   = $(if ($partIndex -eq 0) { $Capture } else { '' })
                edit      = $isStatus
                plainOnly = $false
            })
        $partIndex++
    }

    $true
}
