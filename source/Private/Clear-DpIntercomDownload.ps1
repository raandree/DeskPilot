function Clear-DpIntercomDownload {
    <#
    .SYNOPSIS
        Abandons an in-flight Intercom attachment fetch.
    .DESCRIPTION
        A file the operator sent is fetched across two Telegram calls and lands on
        a later pump tick, so it outlives the dispatch that started it and carries
        its own copy of the chat it came from. When that chat loses its authority
        the fetch has to go with it, or the file arrives as a prompt and its
        acknowledgement is addressed to a chat DeskPilot no longer trusts.

        Clearing the stage is what stops the pump advancing it; the rest is reset
        so nothing stale can be read back out of the block later.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Resets in-process Intercom state on the accept thread; ShouldProcess is not meaningful there.')]
    param()

    $intercom = $script:DeskPilot.Intercom
    if (-not $intercom -or -not $intercom.Download) { return }

    $download = $intercom.Download
    $download.stage = ''
    $download.task = $null
    $download.fileId = ''
    $download.fileName = ''
    $download.mimeType = ''
    $download.isImage = $false
    $download.caption = ''
    $download.chatId = ''
    $download.startedUtc = $null
}
