function Add-DpIntercomPairingCandidate {
    <#
    .SYNOPSIS
        Records a chat that messaged the bot while pairing is open.
    .DESCRIPTION
        Solves the chicken-and-egg that otherwise blocks setup completely:
        Intercom will not listen until it knows which chat is the operator's, so
        the bot cannot answer - not even /start - and the operator has no way to
        learn their own chat id from it.

        While the operator holds a pairing window open from Settings, the poller
        runs with an empty allow-list. Every update therefore comes back
        'rejected' and executes nothing; this function keeps the sender as a
        candidate the operator can then confirm with one click.

        Nothing is adopted automatically. Auto-trusting whoever messages the bot
        first would hand control of the machine to anyone who guessed the bot's
        username, so the choice stays an explicit human decision made at the
        machine.
    .PARAMETER Command
        The rejected command record from ConvertFrom-DpIntercomUpdate.
    .PARAMETER MaxCandidates
        The most candidates to keep, so a flood cannot grow the list without
        bound or push the real one off the top.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Command,

        [ValidateRange(1, 50)]
        [int]$MaxCandidates = 5
    )

    $pairing = $script:DeskPilot.Intercom.Pairing
    if (-not $pairing -or -not $pairing.active) { return }

    $chatId = [string]$Command.chatId
    if ([string]::IsNullOrWhiteSpace($chatId)) { return }

    $existing = @($pairing.candidates) | Where-Object { [string]$_.chatId -eq $chatId } | Select-Object -First 1
    if ($existing) {
        $existing.preview = [string]$Command.preview
        $existing.seenUtc = [DateTime]::UtcNow.ToString('o')
        return
    }

    if ($pairing.candidates.Count -ge $MaxCandidates) { return }

    $pairing.candidates.Add([ordered]@{
            chatId   = $chatId
            fromName = [string]$Command.fromName
            preview  = [string]$Command.preview
            seenUtc  = [DateTime]::UtcNow.ToString('o')
        })
    Add-DpIntercomLog -Direction 'system' -Kind 'pairing' -Detail "Saw a message from chat $chatId ($([string]$Command.fromName)). Waiting for you to confirm it."
}
