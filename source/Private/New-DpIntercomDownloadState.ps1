function New-DpIntercomDownloadState {
    <#
    .SYNOPSIS
        Returns an empty Intercom file batch.
    .DESCRIPTION
        The files the operator sends from their phone are collected into one
        batch, fetched one at a time and handed to the agent as one prompt.
        Several files sent together arrive as several Messages - Telegram
        delivers an Album as one Message per file, with the caption on just one
        of them - so the batch is what keeps them, and that caption, together.

        Each fetch takes two Telegram calls. Both are started on one pump tick
        and reaped on a later one, because a multi-megabyte download on the
        accept thread would freeze the window.

        The shape is defined once, here, for Initialize-DpIntercom and
        Clear-DpIntercomDownload alike: under Set-StrictMode -Version Latest a
        key either of them forgot would be a terminating error on first read.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory record; it changes no state.')]
    param()

    @{
        # The file being fetched: 'lookup' while getFile runs, 'fetch' while its
        # content downloads, and empty between files.
        stage       = ''
        task        = $null
        fileId      = ''
        fileName    = ''
        mimeType    = ''
        isImage     = $false
        # The chat the batch answers to, and the words sent with any of its files.
        chatId      = ''
        caption     = ''
        startedUtc  = $null
        # When the newest file arrived. Telegram never says how many files an
        # Album holds, so an Album is complete once none has arrived for a moment.
        lastItemUtc = $null
        # Two of Telegram's Albums, which hold at most ten files each.
        maxFiles    = 20
        albums      = [System.Collections.Generic.List[string]]::new()
        pending     = [System.Collections.Generic.List[hashtable]]::new()
        saved       = [System.Collections.Generic.List[hashtable]]::new()
        failed      = [System.Collections.Generic.List[hashtable]]::new()
        # Files past maxFiles, counted and reported once rather than refused one
        # message at a time.
        refused     = 0
        # Chats already asked to wait while the batch belongs to another chat.
        toldChats   = [System.Collections.Generic.List[string]]::new()
        # Files of a group Album that did not mention Intercom themselves, held
        # unfetched for a short while in case the file with the caption does.
        held        = [System.Collections.Generic.List[hashtable]]::new()
    }
}
