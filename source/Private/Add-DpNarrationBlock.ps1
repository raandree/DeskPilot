function Add-DpNarrationBlock {
    <#
    .SYNOPSIS
        Appends one narration block to a Turn's narration list, within a bound.
    .DESCRIPTION
        The Engine echoes the model's own text on EVERY tool-calling iteration, but
        Invoke-Shp returns only the LAST iteration's content. Everything the model
        said while it was working - "let me check the branch first", "the counts
        differ, so I will pin down why" - is streamed and then lost, which is why a
        finished Turn used to show far less than it actually did.

        A Turn accumulates that text between tool calls and seals it here, one block
        per tool-call boundary. The boundary is the signal because the Engine writes
        its content deltas before it dispatches the iteration's tool calls, so the
        text buffered when a tool call arrives is exactly what the model said before
        reaching for that tool. Matching on the final answer instead would fail on a
        retry, on a coalesced frame, and on any answer that repeats earlier text.

        The list is bounded, because an agentic Turn can run for dozens of
        iterations and every block is persisted to conversations.json. When the
        total exceeds the bound the OLDEST blocks are dropped and replaced by a
        single marker that states how many are missing - a silent drop would make
        the transcript lie about what happened. The marker is rebuilt on every call
        rather than incremented in place, so a list trimmed repeatedly still reports
        one cumulative total.
    .PARAMETER Block
        The blocks accumulated so far, oldest first. May include a marker block from
        a previous trim.
    .PARAMETER Text
        The buffered narration to seal. Blank text is discarded: it means the model
        went straight from one tool call to the next with nothing to say.
    .PARAMETER MaxLength
        Total character budget across all block text. Defaults to 32 KB.
    .OUTPUTS
        System.Collections.Hashtable[]

        The new ordered block list. Each block is { index; text }; a marker block
        also carries { elided }.
    #>
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param(
        [Parameter()]
        [AllowEmptyCollection()]
        [AllowNull()]
        [hashtable[]]$Block = @(),

        [Parameter()]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Text,

        [Parameter()]
        [ValidateRange(256, 1048576)]
        [int]$MaxLength = 32768
    )

    $real = [System.Collections.Generic.List[hashtable]]::new()
    $elided = 0
    foreach ($existing in @($Block)) {
        if ($null -eq $existing) { continue }
        if ($existing.ContainsKey('elided')) { $elided += [int]$existing.elided; continue }
        $real.Add($existing)
    }

    $trimmed = if ($null -eq $Text) { '' } else { $Text.Trim() }
    if ($trimmed.Length -gt 0) {
        $nextIndex = $elided
        foreach ($existing in $real) {
            if ($existing.ContainsKey('index') -and [int]$existing.index -ge $nextIndex) { $nextIndex = [int]$existing.index + 1 }
        }
        $real.Add(@{ index = $nextIndex; text = $trimmed })
    }

    $total = 0
    foreach ($existing in $real) { $total += ([string]$existing.text).Length }
    # Keep the newest block even when it alone exceeds the budget: dropping it would
    # leave a marker and nothing to read.
    while ($total -gt $MaxLength -and $real.Count -gt 1) {
        $total -= ([string]$real[0].text).Length
        $real.RemoveAt(0)
        $elided++
    }

    $result = [System.Collections.Generic.List[hashtable]]::new()
    if ($elided -gt 0) {
        $noun = if ($elided -eq 1) { 'step' } else { 'steps' }
        $result.Add(@{ index = -1; elided = $elided; text = "($elided earlier $noun elided.)" })
    }
    $result.AddRange($real)

    # Unary comma: without it a single-block list is unrolled to a bare hashtable.
    , $result.ToArray()
}
