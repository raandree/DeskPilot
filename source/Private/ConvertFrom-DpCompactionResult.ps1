function ConvertFrom-DpCompactionResult {
    <#
    .SYNOPSIS
        Cleans the Model output into a Conversation compaction summary.
    .DESCRIPTION
        Normalises whatever the compaction Turn returned into summary text ready to
        replace the older history: it strips an outer Markdown code fence, drops a
        leading label line (for example "Here is the summary:"), trims surrounding
        whitespace, collapses runs of blank lines, and applies a hard character
        cap. Returns an empty string when there is nothing usable, so the caller
        can refuse the compaction rather than storing an empty summary.
    .PARAMETER Text
        The raw text returned by the compaction Turn (result.Content).
    .PARAMETER MaxLength
        A hard character cap for the summary. Default 4000.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [string]$Text,

        [int]$MaxLength = 4000
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }

    $value = $Text.Trim()

    # Strip a single outer fenced code block wrapping the whole answer.
    if ($value -match '^```[^\r\n]*\r?\n([\s\S]*?)\r?\n```$') {
        $value = $Matches[1].Trim()
    }

    # Drop a leading label line such as "Summary:" or "Here is the summary:".
    $lines = @($value -split '\r?\n')
    if ($lines.Count -gt 1 -and $lines[0] -match '(?i)^\s*(here is|summary|briefing)\b[^\r\n]*:\s*$') {
        $value = (($lines[1..($lines.Count - 1)]) -join "`n").Trim()
    }

    # Collapse three-or-more consecutive newlines to a single blank line.
    $value = [regex]::Replace($value, '(\r?\n){3,}', "`n`n").Trim()
    if ($value -eq '') { return '' }

    if ($value.Length -gt $MaxLength) {
        $value = $value.Substring(0, $MaxLength).Trim()
        $value += [char]0x2026
    }

    $value
}
