function Format-DpIntercomMessage {
    <#
    .SYNOPSIS
        Composes an Intercom message and splits it into Telegram-safe chunks.
    .DESCRIPTION
        Builds the message text from structured parts - a title, zero or more
        short fact lines, and an optional long body - then splits the result into
        chunks no longer than MaxLength, preferring paragraph boundaries, then
        line boundaries, then a hard cut. Multi-part results are marked "(n/m)".

        Every part is bounded before composition, so an over-long agent-authored
        question cannot produce an unbounded message. The output is plain text:
        Intercom sends without a Telegram parse mode, so nothing forwarded here is
        ever interpreted as markup.
    .PARAMETER Title
        The first line of the message.
    .PARAMETER Line
        Short fact lines rendered under the title, one per line.
    .PARAMETER Body
        Optional long text (for example an agent question or a final answer).
    .PARAMETER MaxLength
        The per-chunk limit. Defaults to Telegram's 4096-character message cap.
    .PARAMETER MaxTotalLength
        The overall cap applied to the body before splitting.
    .OUTPUTS
        System.String[]
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Title,

        [AllowEmptyCollection()]
        [string[]]$Line = @(),

        [AllowNull()]
        [string]$Body,

        [ValidateRange(64, 4096)]
        [int]$MaxLength = 4096,

        [ValidateRange(64, 200000)]
        [int]$MaxTotalLength = 40000
    )

    $builder = [System.Text.StringBuilder]::new()
    $null = $builder.Append($Title.Trim())

    foreach ($item in $Line) {
        if ([string]::IsNullOrWhiteSpace($item)) { continue }
        $null = $builder.Append("`n").Append($item.Trim())
    }

    if (-not [string]::IsNullOrWhiteSpace($Body)) {
        $bodyText = $Body.Trim()
        if ($bodyText.Length -gt $MaxTotalLength) {
            $bodyText = $bodyText.Substring(0, $MaxTotalLength) + "`n... (truncated)"
        }
        $null = $builder.Append("`n`n").Append($bodyText)
    }

    $text = $builder.ToString()
    if ($text.Length -le $MaxLength) { return @($text) }

    # Reserve room for the " (n/m)" suffix every part of a split message carries.
    $chunkLimit = $MaxLength - 12
    $chunks = [System.Collections.Generic.List[string]]::new()
    $remaining = $text

    while ($remaining.Length -gt $chunkLimit) {
        $window = $remaining.Substring(0, $chunkLimit)
        $cut = $window.LastIndexOf("`n`n")
        if ($cut -lt [int]($chunkLimit / 4)) { $cut = $window.LastIndexOf("`n") }
        if ($cut -lt [int]($chunkLimit / 4)) { $cut = $chunkLimit }
        $chunks.Add($remaining.Substring(0, $cut).TrimEnd())
        $remaining = $remaining.Substring($cut).TrimStart()
    }
    if ($remaining.Length -gt 0) { $chunks.Add($remaining) }

    $total = $chunks.Count
    $numbered = for ($index = 0; $index -lt $total; $index++) {
        '{0} ({1}/{2})' -f $chunks[$index], ($index + 1), $total
    }
    @($numbered)
}
