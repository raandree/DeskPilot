function Start-DpIntercomDownload {
    <#
    .SYNOPSIS
        Begins fetching a file the operator sent from their phone.
    .DESCRIPTION
        Starts the first of the two Telegram calls a file needs (getFile, then the
        content) and hands the rest to Update-DpIntercomDownload on later pump
        ticks. Nothing is awaited here: the Host Server accepts on one thread.

        The size Telegram reports is checked before anything is fetched, so an
        oversized file costs one small request rather than a download that is
        thrown away at the end.
    .PARAMETER Attachment
        The file reference from Get-DpIntercomAttachmentRef.
    .PARAMETER Caption
        The words the operator sent with the file, if any.
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
        [string]$Caption = ''
    )

    $state = $script:DeskPilot
    $intercom = $state.Intercom
    $download = $intercom.Download

    if ($download.stage) {
        $null = Send-DpIntercomMessage -Title 'One file at a time, please.' -Line @('I am still fetching the last one.') -Kind 'notice'
        return
    }
    if ([string]::IsNullOrWhiteSpace([string]$Attachment.fileId)) {
        $null = Send-DpIntercomMessage -Title 'I could not read that attachment.' -Line @('Try sending it as a file.') -Kind 'failed'
        return
    }

    $maxMB = 20
    if ($state.Settings.intercom) { $maxMB = [int]$state.Settings.intercom.maxAttachmentMB }
    if ([long]$Attachment.size -gt ([long]$maxMB * 1MB)) {
        $null = Send-DpIntercomMessage -Title 'That file is too big.' -Line @(
            "$([string]$Attachment.fileName) is larger than the $maxMB MB limit.",
            'Put it in the project folder and tell me where to look instead.'
        ) -Kind 'refused'
        return
    }

    try {
        $requestParams = @{
            Client    = $intercom.Client
            Token     = $intercom.Token
            Operation = 'getFile'
            Payload   = @{ file_id = [string]$Attachment.fileId }
        }
        $download.task = Invoke-DpTelegramRequest @requestParams
        $download.stage = 'lookup'
        $download.fileId = [string]$Attachment.fileId
        $download.fileName = [string]$Attachment.fileName
        $download.mimeType = [string]$Attachment.mimeType
        $download.isImage = [bool]$Attachment.isImage
        $download.caption = $Caption
        $download.startedUtc = [DateTime]::UtcNow
        Add-DpIntercomLog -Direction 'in' -Kind 'attachment' -Detail "Fetching $([string]$Attachment.fileName)."
        $null = Send-DpIntercomMessage -Title 'Fetching that file...' -Kind 'ack'
    }
    catch {
        $intercom.Counters.errors++
        $download.stage = ''
        $download.task = $null
        $null = Send-DpIntercomMessage -Title 'I could not fetch that file.' -Line @((Hide-DpIntercomSecret -Text "$_")) -Kind 'failed'
    }
}
