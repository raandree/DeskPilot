function Get-DpIntercomKeyboard {
    <#
    .SYNOPSIS
        Builds a Telegram inline keyboard, or nothing when one would not help.
    .DESCRIPTION
        Turns a list of choices into the `inline_keyboard` rows Telegram renders as
        tappable buttons under a message - the affordance BotFather uses, and the
        difference between reading a numbered list at a bus stop and tapping once.

        Two hard limits shape this. `callback_data` is capped at **64 bytes**, so
        the payload carries indices and a nonce rather than the label; a choice
        whose data would exceed the cap costs the whole keyboard rather than
        shipping a button that silently fails when tapped. And a label longer than
        a phone's width wraps badly, so it is truncated for the button while the
        message body still carries the full text.

        Returning `$null` rather than an empty keyboard is deliberate: the caller
        omits `reply_markup` entirely and the message stays a plain one that can
        still be answered by replying.
    .PARAMETER Choice
        The choices, each `@{ label; data }`. Order is preserved.
    .PARAMETER PerRow
        How many buttons per row. One is the readable default for wordy labels.
    .OUTPUTS
        System.Collections.Hashtable (a reply_markup) or $null.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Choice,

        [ValidateRange(1, 4)]
        [int]$PerRow = 1
    )

    $items = @($Choice | Where-Object { $_ })
    if ($items.Count -eq 0) { return $null }

    $rows = [System.Collections.Generic.List[object]]::new()
    $row = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $items) {
        $data = [string](Get-DpPropertyValue -InputObject $item -Name @('data') -Default '')
        $label = [string](Get-DpPropertyValue -InputObject $item -Name @('label') -Default '')
        if ([string]::IsNullOrWhiteSpace($data) -or [string]::IsNullOrWhiteSpace($label)) { return $null }
        if ([System.Text.Encoding]::UTF8.GetByteCount($data) -gt 64) { return $null }
        if ($label.Length -gt 64) { $label = $label.Substring(0, 61) + '...' }

        $row.Add(@{ text = $label; callback_data = $data })
        if ($row.Count -ge $PerRow) {
            $rows.Add(@($row.ToArray()))
            $row = [System.Collections.Generic.List[object]]::new()
        }
    }
    if ($row.Count -gt 0) { $rows.Add(@($row.ToArray())) }

    @{ inline_keyboard = @($rows.ToArray()) }
}
