function Format-DpIntercomTable {
    <#
    .SYNOPSIS
        Renders a Markdown table into something readable on a phone.
    .DESCRIPTION
        Telegram has no table support at all - the Bot API offers bold, italic,
        underline, strike, spoiler, code, pre, blockquote and links, and nothing
        else. A table can therefore only be approximated, and the approximation
        has to depend on how wide it is.

        A narrow table becomes a monospaced block with its columns padded to line
        up. That only works while the lines are short enough not to wrap: once
        Telegram wraps a line inside <pre>, the alignment it was there to provide
        is gone and the result reads worse than no table at all.

        A wide table becomes one labelled record per row instead, which wraps
        naturally as prose and stays legible on any width.

        Either way the row count is capped. A 141-row table is several screens of
        noise on a phone; the machine is where you read the whole thing.
    .PARAMETER Line
        The table's rows, pipe-delimited and already HTML-escaped, with the
        Markdown separator row removed.
    .PARAMETER MaxWidth
        The widest a padded row may be before records are used instead. Telegram
        wraps a monospaced line well before this on a narrow phone.
    .PARAMETER MaxRows
        How many data rows to include before summarising the remainder.
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Line,

        [ValidateRange(20, 200)]
        [int]$MaxWidth = 42,

        [ValidateRange(1, 500)]
        [int]$MaxRows = 15
    )

    # Explicit lists throughout: @(...) unrolls a single row back into bare
    # strings, and the next .Count then throws under strict mode.
    $rows = [System.Collections.Generic.List[string[]]]::new()
    foreach ($item in $Line) {
        $cells = @($item.Trim().Trim('|') -split '\|' | ForEach-Object { $_.Trim() })
        if ($cells.Count -gt 0) { $rows.Add($cells) }
    }
    if ($rows.Count -eq 0) { return '' }

    $header = $rows[0]
    $shown = [System.Collections.Generic.List[string[]]]::new()
    for ($index = 1; $index -lt $rows.Count -and $shown.Count -lt $MaxRows; $index++) {
        $shown.Add($rows[$index])
    }
    $omitted = $rows.Count - 1 - $shown.Count

    $columns = 0
    foreach ($row in $rows) { if ($row.Count -gt $columns) { $columns = $row.Count } }

    $measured = [System.Collections.Generic.List[string[]]]::new()
    $measured.Add($header)
    foreach ($row in $shown) { $measured.Add($row) }

    $widths = [System.Collections.Generic.List[int]]::new()
    for ($column = 0; $column -lt $columns; $column++) {
        $widest = 0
        foreach ($row in $measured) {
            $cell = if ($column -lt $row.Count) { [string]$row[$column] } else { '' }
            if ($cell.Length -gt $widest) { $widest = $cell.Length }
        }
        $widths.Add($widest)
    }

    $totalWidth = 2 * [Math]::Max(0, $columns - 1)
    foreach ($width in $widths) { $totalWidth += $width }

    $output = [System.Collections.Generic.List[string]]::new()

    if ($totalWidth -le $MaxWidth) {
        $pad = {
            param([string[]]$Row)
            $parts = [System.Collections.Generic.List[string]]::new()
            for ($column = 0; $column -lt $columns; $column++) {
                $cell = if ($column -lt $Row.Count) { [string]$Row[$column] } else { '' }
                $parts.Add($cell.PadRight($widths[$column]))
            }
            (($parts -join '  ')).TrimEnd()
        }
        $block = [System.Collections.Generic.List[string]]::new()
        $block.Add((& $pad $header))
        foreach ($row in $shown) { $block.Add((& $pad $row)) }
        $output.Add('<pre>' + ($block -join "`n") + '</pre>')
    }
    else {
        # One labelled record per row. Wide columns wrap as prose instead of
        # shredding a monospaced block nobody can read.
        $blocks = [System.Collections.Generic.List[string]]::new()
        foreach ($row in $shown) {
            $fields = [System.Collections.Generic.List[string]]::new()
            for ($column = 0; $column -lt $columns; $column++) {
                $value = if ($column -lt $row.Count) { [string]$row[$column] } else { '' }
                if ([string]::IsNullOrWhiteSpace($value)) { continue }
                $label = if ($column -lt $header.Count -and -not [string]::IsNullOrWhiteSpace($header[$column])) {
                    [string]$header[$column]
                }
                else {
                    "Column $($column + 1)"
                }
                $fields.Add("<b>$label</b>: $value")
            }
            if ($fields.Count -gt 0) { $blocks.Add(($fields -join "`n")) }
        }
        $output.Add(($blocks -join "`n`n"))
    }

    if ($omitted -gt 0) {
        $output.Add("... and $omitted more row$(if ($omitted -ne 1) { 's' }). Open DeskPilot to see the full table.")
    }

    ($output -join "`n")
}
