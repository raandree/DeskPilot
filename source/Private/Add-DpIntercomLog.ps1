function Add-DpIntercomLog {
    <#
    .SYNOPSIS
        Records one Intercom event in the bounded audit ring.
    .DESCRIPTION
        Every accepted message, every rejected message, every outbound message and
        every transport error is recorded here with a UTC timestamp. A rejection is
        a possible attack and is recorded as loudly as an acceptance, so after a
        bad day the operator can reconstruct what reached the machine.

        The ring is capped so a flood cannot grow it without bound, and the detail
        is truncated so one long message cannot dominate it. Text is redacted, so a
        token can never reach the log.

        An inbound event also records which chat it came from and who sent it.
        Once more than one chat can reach DeskPilot, "what happened" is only half
        an audit trail: after a bad /undo the log has to answer who. Telegram
        supplies the sender name and DeskPilot does not verify it, so it is a
        display label beside the chat id rather than an identity.

        A coalesced event is noise by volume rather than by meaning: group
        chatter that was meant for someone else. One entry per chat and kind
        stands for all of it, counts it, and moves to the newest position, so a
        busy group can never evict the rejections and errors the ring is for.
    .PARAMETER Direction
        'in', 'out' or 'system'.
    .PARAMETER Kind
        A short event name, for example 'prompt', 'rejected' or 'error'.
    .PARAMETER Detail
        A short human-readable description.
    .PARAMETER ChatId
        The Telegram chat the event belongs to, when it belongs to one.
    .PARAMETER From
        The sender's display name as Telegram reported it. Untrusted.
    .PARAMETER Accepted
        Whether the event was acted on. Rejections are highlighted in the UI.
    .PARAMETER Coalesce
        Fold the event into the chat's existing entry of the same kind. The entry
        carries messageCount and sinceUtc, the time of the first folded event.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('in', 'out', 'system')]
        [string]$Direction,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Kind,

        [AllowEmptyString()]
        [string]$Detail = '',

        [AllowNull()]
        [AllowEmptyString()]
        [string]$ChatId = '',

        [AllowNull()]
        [AllowEmptyString()]
        [string]$From = '',

        [bool]$Accepted = $true,

        [switch]$Coalesce
    )

    $intercom = $script:DeskPilot.Intercom
    # An empty collection is falsy in PowerShell, so "-not $intercom.Log" was true
    # for the empty ring - the audit log could never record its first entry, and
    # therefore never recorded anything at all.
    if (-not $intercom -or $null -eq $intercom.Log) { return }

    $text = Hide-DpIntercomSecret -Text $Detail
    if ($text.Length -gt 300) { $text = $text.Substring(0, 300) + '...' }

    # Bounded and redacted for the same reasons the detail is: the sender name is
    # whatever Telegram was told, and it is rendered in the Settings panel.
    $fromName = Hide-DpIntercomSecret -Text $From
    if ($fromName.Length -gt 60) { $fromName = $fromName.Substring(0, 60) }

    $now = [DateTime]::UtcNow.ToString('o')
    $chat = ([string]$ChatId).Trim()
    $entry = [ordered]@{
        utc       = $now
        direction = $Direction
        kind      = $Kind
        detail    = $text
        chatId    = $chat
        from      = $fromName
        accepted  = $Accepted
    }

    if ($Coalesce) {
        $entry['messageCount'] = 1
        $entry['sinceUtc'] = $now
        for ($index = $intercom.Log.Count - 1; $index -ge 0; $index--) {
            $previous = $intercom.Log[$index]
            if ($previous -is [System.Collections.IDictionary] -and $previous.Contains('messageCount') -and
                [string]$previous['kind'] -eq $Kind -and [string]$previous['chatId'] -eq $chat) {
                $entry['messageCount'] = [int]$previous['messageCount'] + 1
                $entry['sinceUtc'] = [string]$previous['sinceUtc']
                $intercom.Log.RemoveAt($index)
                break
            }
        }
    }

    $intercom.Log.Add($entry)

    $maxEntries = 200
    while ($intercom.Log.Count -gt $maxEntries) { $intercom.Log.RemoveAt(0) }
}
