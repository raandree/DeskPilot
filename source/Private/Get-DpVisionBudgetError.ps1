function Get-DpVisionBudgetError {
    <#
    .SYNOPSIS
        Rejects an image Attachment set too large to inline into one Turn.
    .DESCRIPTION
        The Engine inlines every image Attachment into the Turn's request body as
        a base64 data URI, which is ~4/3 the size of the file on disk before JSON
        escaping. Nothing downstream bounded that, so an un-downscaled camera
        photo made the Copilot endpoint answer a bare HTTP 413 that reached the
        user as a raw EndInvoke exception with nothing in it to act on.

        The browser downscales an oversized image before uploading it, but the
        browser is not a trust boundary and an Attachment also arrives through
        Intercom, where there is no browser at all. The budget is therefore
        enforced here, against the bytes actually on disk, and answered with a
        message that names the file and its real size.

        The defaults keep one encoded image under the ~5 MB per-image ceiling the
        providers behind Copilot document. The total is more than twice that but
        far below any plausible body limit, so it bounds a runaway set - a folder
        of photos dropped on the composer - without capping a realistic Turn.
    .PARAMETER Path
        The resolved image Attachment paths for one Turn.
    .PARAMETER MaxImageBytes
        The largest a single image Attachment may be on disk.
    .PARAMETER MaxTotalBytes
        The largest every image Attachment in one Turn may be on disk together.
    .OUTPUTS
        System.String

        An empty string when the set fits, otherwise the message to show the
        user.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Path,

        [ValidateRange(1, [long]::MaxValue)]
        [long]$MaxImageBytes = 3.5MB,

        [ValidateRange(1, [long]::MaxValue)]
        [long]$MaxTotalBytes = 8MB
    )

    # InvariantCulture: -f formats with the current culture, so on a de-DE host
    # the same message would read '3,5 MB' and every caller matching on it breaks.
    $asMegabytes = {
        param([long]$Bytes)
        ([double]($Bytes / 1MB)).ToString('0.#', [System.Globalization.CultureInfo]::InvariantCulture) + ' MB'
    }

    $total = [long]0
    $count = 0

    foreach ($candidate in $Path) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }

        # FileInfo, not Get-Item: a drive-qualified path is a provider path to the
        # PowerShell cmdlets and throws wherever that PSDrive does not exist.
        # A file that vanished or locked since it was validated is skipped rather
        # than thrown, so the caller never turns it into a 500 quoting its path.
        try { $length = [long]([System.IO.FileInfo]::new($candidate)).Length }
        catch { continue }

        $count++
        $total += $length

        if ($length -gt $MaxImageBytes) {
            $name = [System.IO.Path]::GetFileName($candidate)
            return "'$name' is $(& $asMegabytes $length). A single image must stay under $(& $asMegabytes $MaxImageBytes) to fit in one Turn. Attach a smaller image."
        }
    }

    if ($total -gt $MaxTotalBytes) {
        $noun = if ($count -eq 1) { 'image totals' } else { 'images total' }
        return "$count $noun $(& $asMegabytes $total). One Turn must stay under $(& $asMegabytes $MaxTotalBytes) of images. Remove some and try again."
    }

    ''
}
