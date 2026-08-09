function ConvertTo-DpTelegramHtml {
    <#
    .SYNOPSIS
        Renders Markdown-ish agent text as Telegram-safe HTML.
    .DESCRIPTION
        The agent writes Markdown. Telegram does not render it, so a good answer
        arrives as a wall of ##, ** and pipe-delimited tables.

        Telegram's HTML mode understands a small tag set, which is what makes this
        safe: the text is escaped first and only then are known constructs turned
        into tags, so nothing the agent (or a file it read) wrote can inject
        markup. Anything not recognised stays literal.

        MarkdownV2 was rejected deliberately: it requires escaping a large
        character set, and a single miss makes Telegram reject the whole message -
        losing the result rather than formatting it badly. HTML has a tiny escape
        surface, and the caller still falls back to plain text on a parse error.

        Handled: fenced and inline code, headings, bold, links, bullets, and
        tables. A table is delegated to Format-DpIntercomTable, because Telegram
        has no table support and the only useful rendering depends on how wide it
        is. Italics are deliberately not handled: underscores are far more common
        in paths and identifiers than as emphasis.
    .PARAMETER Text
        The plain text to render.
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text
    )

    if ([string]::IsNullOrEmpty($Text)) { return '' }

    $escape = {
        param([string]$Value)
        $Value.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
    }

    $lines = $Text -split "`r?`n"
    $output = [System.Collections.Generic.List[string]]::new()
    $inFence = $false
    $fence = [System.Collections.Generic.List[string]]::new()
    $table = [System.Collections.Generic.List[string]]::new()

    $flushTable = {
        if ($table.Count -eq 0) { return }
        $output.Add((Format-DpIntercomTable -Line @($table.ToArray())))
        $table.Clear()
    }

    foreach ($line in $lines) {
        if ($line -match '^\s*```') {
            if ($inFence) {
                $output.Add('<pre><code>' + (($fence -join "`n")) + '</code></pre>')
                $fence.Clear()
                $inFence = $false
            }
            else {
                & $flushTable
                $inFence = $true
            }
            continue
        }
        if ($inFence) {
            $fence.Add((& $escape $line))
            continue
        }

        # A table only reads on a phone in a monospaced block, so contiguous
        # pipe rows are gathered and emitted as one <pre>.
        if ($line -match '^\s*\|') {
            if ($line -notmatch '^\s*\|[\s:|-]+\|\s*$') { $table.Add((& $escape $line.Trim())) }
            continue
        }
        & $flushTable

        $rendered = & $escape $line

        # Inline code is protected before anything else rewrites its contents.
        $codes = [System.Collections.Generic.List[string]]::new()
        $rendered = [regex]::Replace($rendered, '`([^`]+)`', {
                param($match)
                $codes.Add($match.Groups[1].Value)
                "`u{0000}$($codes.Count - 1)`u{0000}"
            })

        if ($rendered -match '^\s*#{1,6}\s+(.*)$') {
            $rendered = '<b>' + $Matches[1].Trim() + '</b>'
        }
        elseif ($rendered -match '^\s*([-*+])\s+(.*)$') {
            $rendered = "$([char]0x2022) " + $Matches[2]
        }
        elseif ($rendered -match '^\s*(-{3,}|_{3,}|\*{3,})\s*$') {
            $rendered = [string][char]0x2014
        }

        # Only http(s) becomes a link; anything else stays literal text.
        $rendered = [regex]::Replace($rendered, '\[([^\]]+)\]\((https?://[^\s)]+)\)', {
                param($match)
                '<a href="{0}">{1}</a>' -f $match.Groups[2].Value, $match.Groups[1].Value
            })

        $rendered = [regex]::Replace($rendered, '\*\*(.+?)\*\*', '<b>$1</b>')

        for ($index = 0; $index -lt $codes.Count; $index++) {
            $rendered = $rendered.Replace("`u{0000}$index`u{0000}", '<code>' + $codes[$index] + '</code>')
        }

        $output.Add($rendered)
    }

    & $flushTable
    if ($inFence -and $fence.Count -gt 0) { $output.Add('<pre><code>' + (($fence -join "`n")) + '</code></pre>') }

    ($output -join "`n")
}
