function Get-DpImageMediaType {
    <#
    .SYNOPSIS
        Identifies a raster image from its leading bytes.
    .DESCRIPTION
        Returns the media type for the image formats every current browser can
        render inline - PNG, JPEG, GIF, WebP, BMP, ICO and AVIF - or $null for
        anything else. The decision is made from the file's own signature so a
        renamed file cannot talk the Host Server into serving it under a type the
        browser trusts. Text-based formats (notably SVG) are intentionally not
        recognised: they are script-capable and already readable as text.
    .PARAMETER Bytes
        The file's bytes, or at least its first 12.
    .OUTPUTS
        System.String or $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [byte[]]$Bytes
    )

    if ($null -eq $Bytes -or $Bytes.Length -lt 12) { return $null }

    # Uppercase hex of the first 12 bytes, so each signature is one plain compare.
    $head = [System.BitConverter]::ToString($Bytes, 0, 12).Replace('-', '')

    if ($head.StartsWith('89504E470D0A1A0A')) { return 'image/png' }
    if ($head.StartsWith('FFD8FF')) { return 'image/jpeg' }
    if ($head -match '^474946383[79]61') { return 'image/gif' }
    if ($head.StartsWith('52494646') -and $head.Substring(16, 8) -eq '57454250') { return 'image/webp' }
    if ($head.StartsWith('424D')) { return 'image/bmp' }
    if ($head.StartsWith('00000100')) { return 'image/x-icon' }
    # An ISO base-media file names its brand right after the 'ftyp' box type.
    if ($head.Substring(8, 8) -eq '66747970' -and @('61766966', '61766973') -contains $head.Substring(16, 8)) { return 'image/avif' }

    $null
}
