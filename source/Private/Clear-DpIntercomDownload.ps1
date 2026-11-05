function Clear-DpIntercomDownload {
    <#
    .SYNOPSIS
        Abandons the Intercom file batch.
    .DESCRIPTION
        The files the operator sent are fetched across several pump ticks, so
        the batch outlives the dispatch that started it and carries its own copy
        of the chat it came from. When that chat loses its authority the batch
        has to go with it, or its files arrive as a prompt and the
        acknowledgement is addressed to a chat DeskPilot no longer trusts.

        Every field is reset in place, because callers hold the block by
        reference, so nothing stale can be read back out of it later. Clearing
        the stage and the pending files is what stops the pump advancing it.
    .PARAMETER KeepHeld
        Keep the held files of unmentioned group Albums. A batch that has simply
        finished passes this, so it cannot forget files another Album is still
        waiting to claim; abandoning a batch drops them with everything else.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Resets in-process Intercom state on the accept thread; ShouldProcess is not meaningful there.')]
    param(
        [switch]$KeepHeld
    )

    $intercom = $script:DeskPilot.Intercom
    if (-not $intercom -or -not $intercom.Download) { return }

    $download = $intercom.Download
    $held = $null
    if ($KeepHeld -and $download.ContainsKey('held')) { $held = $download['held'] }

    $empty = New-DpIntercomDownloadState
    foreach ($key in @($empty.Keys)) { $download[$key] = $empty[$key] }
    if ($null -ne $held) { $download['held'] = $held }
}
