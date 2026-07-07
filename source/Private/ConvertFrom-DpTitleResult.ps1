function ConvertFrom-DpTitleResult {
    <#
    .SYNOPSIS
        Cleans the Model's raw output into a short Conversation title.
    .DESCRIPTION
        Turns whatever the title Turn returned into a single clean line suitable
        for a Conversation title: it discards code-fence lines, takes the first
        meaningful line (skipping a leading label line such as 'Here is a title:'),
        strips a leading 'Title:' label, Markdown heading/list markers and
        surrounding quotes/backticks, collapses whitespace, removes trailing
        punctuation, and caps the result to a few words (and a hard character
        limit). Returns an empty string when there is nothing usable, so the caller
        can keep its fallback title.
    .PARAMETER Text
        The raw text returned by the title Turn (result.Content).
    .PARAMETER MaxWords
        The maximum number of words to keep. Default 8.
    .PARAMETER MaxLength
        A hard character cap applied after the word cap. Default 60.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [string]$Text,

        [int]$MaxWords = 8,

        [int]$MaxLength = 60
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }

    # Candidate lines: trimmed, non-empty, and not a Markdown code fence.
    $lines = @($Text -split "`r?`n" |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -ne '' -and $_ -notmatch '^```' })
    if ($lines.Count -eq 0) { return '' }

    # Prefer the first real line, but skip a leading label line ("... title:")
    # that some Models prepend before the answer on the next line.
    $line = $lines[0]
    if ($lines.Count -gt 1 -and $line -match ':\s*$') { $line = $lines[1] }

    # Strip a leading "Title:" label, a Markdown heading (#) or list (-, *) marker.
    # PowerShell -replace is case-insensitive by default.
    $line = $line -replace '^\s*title\s*[:\-]\s*', ''
    $line = $line -replace '^\s*#{1,6}\s*', ''
    $line = $line -replace '^\s*[-*]\s+', ''

    # Strip surrounding straight/smart quotes and backticks.
    $trimChars = [char[]]@([char]0x22, [char]0x27, [char]0x60, [char]0x201C, [char]0x201D)
    $line = $line.Trim($trimChars).Trim()

    # Collapse internal whitespace to single spaces.
    $line = ($line -replace '\s+', ' ').Trim()
    if ($line -eq '') { return '' }

    # Cap the word count.
    $words = @($line -split ' ')
    if ($words.Count -gt $MaxWords) { $line = ($words[0..($MaxWords - 1)] -join ' ') }

    # Remove trailing sentence punctuation a Model may still add.
    $line = $line -replace '[\s\.,;:!?]+$', ''

    # Hard character cap as a last resort (rare for a few-word title).
    if ($line.Length -gt $MaxLength) {
        $line = $line.Substring(0, $MaxLength).Trim()
        $line = $line -replace '[\s\.,;:!?]+$', ''
        $line += [char]0x2026
    }

    $line
}
