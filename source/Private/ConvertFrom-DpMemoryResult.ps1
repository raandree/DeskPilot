function ConvertFrom-DpMemoryResult {
    <#
    .SYNOPSIS
        Cleans the Model output from a memory-extraction Turn into storable notes.
    .DESCRIPTION
        Normalises whatever the extraction Turn returned into the new Agent Memory
        text: strips an outer Markdown code fence, drops a leading label line (for
        example "Updated notes:"), trims whitespace, collapses runs of blank lines,
        and applies a hard character cap on a line boundary where possible. Returns
        an empty string when there is nothing usable; the sentinel the prompt asks
        for on "nothing worth changing" (a bare NO_CHANGE) is also returned as empty
        so the caller keeps the existing memory instead of overwriting it.
    .PARAMETER Text
        The raw text returned by the extraction Turn (result.Content).
    .PARAMETER MaxLength
        A hard character cap for the notes. Default 12000.
    .OUTPUTS
        System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [string]$Text,

        [int]$MaxLength = 12000
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }

    $value = $Text.Trim()

    if ($value -match '^```[^\r\n]*\r?\n([\s\S]*?)\r?\n```$') {
        $value = $Matches[1].Trim()
    }

    # A model told to signal "nothing worth changing" returns this sentinel; treat
    # it as no update rather than overwriting good memory with the word NO_CHANGE.
    if ($value -match '(?i)^no[_\s-]?change\.?$') { return '' }

    $lines = @($value -split '\r?\n')
    if ($lines.Count -gt 1 -and $lines[0] -match '(?i)^\s*(here (is|are)|updated|memory|notes|user profile)\b[^\r\n]*:\s*$') {
        $value = (($lines[1..($lines.Count - 1)]) -join "`n").Trim()
    }

    $value = [regex]::Replace($value, '(\r?\n){3,}', "`n`n").Trim()
    if ($value -eq '') { return '' }

    if ($value.Length -gt $MaxLength) {
        $cut = $value.Substring(0, $MaxLength)
        # Prefer cutting on the last line break so a fact is not sliced in half.
        $lastBreak = $cut.LastIndexOf("`n")
        if ($lastBreak -ge [int]($MaxLength * 0.6)) { $cut = $cut.Substring(0, $lastBreak) }
        $value = $cut.TrimEnd()
    }

    $value
}
