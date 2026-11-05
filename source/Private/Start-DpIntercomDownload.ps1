function Start-DpIntercomDownload {
    <#
    .SYNOPSIS
        Adds a file the operator sent from their phone to the Intercom file batch.
    .DESCRIPTION
        Several files sent together reach the bot as several Messages: Telegram
        delivers an Album as one Message per file, sharing a media group id, and
        puts the caption on just one of them - for documents, usually the last.
        Each file therefore joins the batch already open for its chat, and the
        batch becomes one prompt naming every file once they have all landed
        (Update-DpIntercomDownload). Refusing every file after the first lost
        the rest of the Album, and the caption with it whenever it rode on a
        later file.

        A batch answers to one chat, so a file from another chat is asked to
        wait, once per chat. Past the batch's maxFiles, files are counted and
        reported at the end rather than refused one message at a time.

        In a group that must mention Intercom, only the file carrying the
        Album's caption can. The Album's other files arrive Unaddressed: such a
        file joins a batch its Album was already addressed to, and is otherwise
        held - unfetched and unanswered - until the file with the mention claims
        it, or the pump forgets it.

        Nothing is fetched or awaited here; the pump starts each fetch.
    .PARAMETER Attachment
        The file reference from Get-DpIntercomAttachmentRef.
    .PARAMETER Caption
        The words the operator sent with the file, if any.
    .PARAMETER MediaGroupId
        Telegram's id for the Album the file belongs to; empty for a file sent
        on its own.
    .PARAMETER Unaddressed
        The file came from a group Album Message that did not itself mention
        Intercom. It never opens a batch and never contributes words.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Driven by the pump from an already-authorised message; a prompt on the accept thread would hang the Host Server.')]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Attachment,

        [AllowEmptyString()]
        [string]$Caption = '',

        [AllowEmptyString()]
        [string]$MediaGroupId = '',

        [switch]$Unaddressed
    )

    $intercom = $script:DeskPilot.Intercom
    $download = $intercom.Download
    $chatId = [string](Get-DpPropertyValue -InputObject $intercom -Name @('ReplyChatId') -Default '')
    $isOpen = [bool]$download.stage -or ($download.pending.Count + $download.saved.Count + $download.failed.Count) -gt 0

    # Queues one file, or counts it once the batch is full. Every arrival keeps
    # the batch open a little longer, so an Album is not cut short.
    $addFile = {
        param([hashtable]$File, [string]$Words)

        $download.lastItemUtc = [DateTime]::UtcNow
        $taken = $download.pending.Count + $download.saved.Count + $download.failed.Count
        if ($download.stage) { $taken++ }
        if ($taken -ge [int]$download.maxFiles) {
            $download.refused = [int]$download.refused + 1
            return
        }
        $download.pending.Add($File)
        if (-not [string]::IsNullOrWhiteSpace($Words)) {
            $merged = if ($download.caption) { "$($download.caption)`n`n$Words" } else { $Words }
            # The same bound ConvertFrom-DpIntercomUpdate puts on one Message.
            if ($merged.Length -gt 4000) { $merged = $merged.Substring(0, 4000) }
            $download.caption = $merged
        }
    }

    if ($Unaddressed) {
        if ([string]::IsNullOrWhiteSpace($MediaGroupId)) { return }
        if ($isOpen -and $download.chatId -eq $chatId -and $download.albums.Contains($MediaGroupId)) {
            & $addFile $Attachment ''
        }
        # Held files are small records; the bound only stops a busy group's
        # unmentioned Albums piling up between the pump's sweeps.
        elseif ($download.held.Count -lt 50) {
            $download.held.Add(@{
                    attachment   = $Attachment
                    chatId       = $chatId
                    mediaGroupId = $MediaGroupId
                    receivedUtc  = [DateTime]::UtcNow
                })
        }
        return
    }

    if ($isOpen -and $download.chatId -ne $chatId) {
        if (-not $download.toldChats.Contains($chatId)) {
            $download.toldChats.Add($chatId)
            $null = Send-DpIntercomMessage -Title 'One set of files at a time, please.' -Line @(
                'I am still fetching files sent from another chat.',
                'Send these again in a minute.'
            ) -Kind 'notice'
        }
        return
    }

    if (-not $isOpen) {
        # The files land on later pump ticks, outside the dispatch that set the
        # ambient reply target, so the batch carries its own chat.
        $download.chatId = $chatId
        $download.startedUtc = [DateTime]::UtcNow
        $null = Send-DpIntercomMessage -Title $(if ($MediaGroupId) { 'Fetching your files...' } else { 'Fetching that file...' }) -Kind 'ack'
    }

    if (-not [string]::IsNullOrWhiteSpace($MediaGroupId)) {
        if (-not $download.albums.Contains($MediaGroupId)) { $download.albums.Add($MediaGroupId) }
        # Files of this Album that arrived before the one addressed to
        # Intercom, in the order they came.
        $index = 0
        while ($index -lt $download.held.Count) {
            $candidate = $download.held[$index]
            if ([string]$candidate.chatId -eq $chatId -and [string]$candidate.mediaGroupId -eq $MediaGroupId) {
                $download.held.RemoveAt($index)
                & $addFile $candidate.attachment ''
            }
            else {
                $index++
            }
        }
    }

    & $addFile $Attachment $Caption
}
