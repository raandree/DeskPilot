function ConvertTo-DpSearchRegex {
    <#
    .SYNOPSIS
        Translates a search glob into an anchored, case-insensitive regex.
    .DESCRIPTION
        The search Tools take globs because that is what an editor-hosted
        assistant is used to writing, and a glob is safe in a way a raw regex is
        not: every character except *, ** and ? is escaped, so a pattern can
        match paths but can never become an expression.

        The segment rules are the ones VS Code uses, because they are the ones
        the model has learnt:

        - `*` matches within one path segment and never crosses a `/`.
        - `?` matches one character within a segment.
        - `**/` matches zero or more whole segments, so `**/*.ps1` also matches a
          file at the root.
        - a trailing `**` matches the rest of the path, separators included.

        The returned regex carries a one-second match timeout. A glob cannot
        backtrack catastrophically, but the same helper is what bounds the
        Tool's own matching, and one bound is easier to trust than two.
    .PARAMETER Glob
        The glob to translate. Backslashes are read as path separators, so a
        Windows-shaped pattern behaves like the forward-slash form.
    .OUTPUTS
        System.Text.RegularExpressions.Regex
    #>
    [CmdletBinding()]
    [OutputType([regex])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Glob
    )

    $normalized = ($Glob -replace '\\', '/')
    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.Append('^')

    $index = 0
    while ($index -lt $normalized.Length) {
        $current = [string]$normalized[$index]
        if ($current -eq '*') {
            $isDouble = ($index + 1) -lt $normalized.Length -and $normalized[$index + 1] -eq '*'
            if (-not $isDouble) {
                [void]$builder.Append('[^/]*')
                $index++
                continue
            }
            # '**/' has to be able to match nothing at all, or '**/*.ps1' would
            # miss a file that sits at the root - the single most common way a
            # recursive glob is written.
            if (($index + 2) -lt $normalized.Length -and $normalized[$index + 2] -eq '/') {
                [void]$builder.Append('(?:[^/]+/)*')
                $index += 3
                continue
            }
            [void]$builder.Append('.*')
            $index += 2
            continue
        }
        if ($current -eq '?') {
            [void]$builder.Append('[^/]')
            $index++
            continue
        }
        [void]$builder.Append([regex]::Escape($current))
        $index++
    }

    [void]$builder.Append('$')
    [regex]::new($builder.ToString(), [System.Text.RegularExpressions.RegexOptions]::IgnoreCase, [timespan]::FromSeconds(1))
}
