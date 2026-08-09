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
    .PARAMETER Direction
        'in', 'out' or 'system'.
    .PARAMETER Kind
        A short event name, for example 'prompt', 'rejected' or 'error'.
    .PARAMETER Detail
        A short human-readable description.
    .PARAMETER Accepted
        Whether the event was acted on. Rejections are highlighted in the UI.
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

        [bool]$Accepted = $true
    )

    $intercom = $script:DeskPilot.Intercom
    # An empty collection is falsy in PowerShell, so "-not $intercom.Log" was true
    # for the empty ring - the audit log could never record its first entry, and
    # therefore never recorded anything at all.
    if (-not $intercom -or $null -eq $intercom.Log) { return }

    $text = Hide-DpIntercomSecret -Text $Detail
    if ($text.Length -gt 300) { $text = $text.Substring(0, 300) + '...' }

    $intercom.Log.Add([ordered]@{
            utc       = [DateTime]::UtcNow.ToString('o')
            direction = $Direction
            kind      = $Kind
            detail    = $text
            accepted  = $Accepted
        })

    $maxEntries = 200
    while ($intercom.Log.Count -gt $maxEntries) { $intercom.Log.RemoveAt(0) }
}
