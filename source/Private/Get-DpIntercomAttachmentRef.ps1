function Get-DpIntercomAttachmentRef {
    <#
    .SYNOPSIS
        Extracts the file a Telegram message carries, if any.
    .DESCRIPTION
        A Telegram file message has no 'text' - the words live in 'caption' and
        the file sits in one of several differently shaped members - so reading
        only 'text' made an attachment disappear with no reply at all.

        Returns the file id to fetch, a safe leaf file name, the MIME type and the
        reported size, or $null when the message carries no file.

        The name is sanitised here rather than at the point of writing: it comes
        from whoever sent the message, and a name is the one part of an upload
        that can escape the folder it was meant for.
    .PARAMETER Message
        The Telegram message object.
    .OUTPUTS
        System.Collections.Hashtable, or $null.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Message
    )

    if ($null -eq $Message) { return $null }

    $safeName = {
        param([string]$Name, [string]$Fallback)
        $candidate = [string]$Name
        if ([string]::IsNullOrWhiteSpace($candidate)) { $candidate = $Fallback }
        # Take the leaf only, then strip anything a file name may not contain.
        $candidate = $candidate -replace '.*[\\/]', ''
        foreach ($invalid in [System.IO.Path]::GetInvalidFileNameChars()) {
            $candidate = $candidate.Replace([string]$invalid, '_')
        }
        $candidate = $candidate.Trim('.', ' ')
        if ([string]::IsNullOrWhiteSpace($candidate)) { $candidate = $Fallback }
        if ($candidate.Length -gt 120) { $candidate = $candidate.Substring($candidate.Length - 120) }
        $candidate
    }

    $stamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')

    $document = Get-DpPropertyValue -InputObject $Message -Name @('document') -Default $null
    if ($document) {
        return @{
            fileId   = [string](Get-DpPropertyValue -InputObject $document -Name @('file_id') -Default '')
            fileName = & $safeName (Get-DpPropertyValue -InputObject $document -Name @('file_name') -Default '') "telegram-$stamp.bin"
            mimeType = [string](Get-DpPropertyValue -InputObject $document -Name @('mime_type') -Default 'application/octet-stream')
            size     = [long](Get-DpPropertyValue -InputObject $document -Name @('file_size') -Default 0)
            isImage  = $false
        }
    }

    # A photo arrives as an array of sizes, smallest first; the last is the one
    # worth looking at.
    $photo = @(Get-DpPropertyValue -InputObject $Message -Name @('photo') -Default @())
    if ($photo.Count -gt 0) {
        $largest = $photo[$photo.Count - 1]
        return @{
            fileId   = [string](Get-DpPropertyValue -InputObject $largest -Name @('file_id') -Default '')
            fileName = "telegram-photo-$stamp.jpg"
            mimeType = 'image/jpeg'
            size     = [long](Get-DpPropertyValue -InputObject $largest -Name @('file_size') -Default 0)
            isImage  = $true
        }
    }

    foreach ($kind in @('video', 'audio', 'voice', 'video_note', 'animation')) {
        $media = Get-DpPropertyValue -InputObject $Message -Name @($kind) -Default $null
        if (-not $media) { continue }
        $mime = [string](Get-DpPropertyValue -InputObject $media -Name @('mime_type') -Default 'application/octet-stream')
        $extension = switch -Regex ($mime) {
            'audio/ogg' { '.ogg'; break }
            'audio/mpeg' { '.mp3'; break }
            'video/mp4' { '.mp4'; break }
            default { '.bin' }
        }
        return @{
            fileId   = [string](Get-DpPropertyValue -InputObject $media -Name @('file_id') -Default '')
            fileName = & $safeName (Get-DpPropertyValue -InputObject $media -Name @('file_name') -Default '') "telegram-$kind-$stamp$extension"
            mimeType = $mime
            size     = [long](Get-DpPropertyValue -InputObject $media -Name @('file_size') -Default 0)
            isImage  = $false
        }
    }

    $null
}
