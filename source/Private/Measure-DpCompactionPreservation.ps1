function Measure-DpCompactionPreservation {
    <#
    .SYNOPSIS
        Measures what a compaction summary kept from the Turns it replaces.
    .DESCRIPTION
        Compaction trades tokens for memory, and the trade is only safe if the
        summary still carries what the Conversation established. This is the
        deterministic check on that: it looks for the five sections the compaction
        prompt asks for (goals, constraints, decisions, unresolved work, source
        references) and for the source references the summarised Turns actually
        named - file names and paths - and reports which of them survived.

        It is a shape and coverage measure, not a quality judgement. It can prove
        that build.ps1 was named in the transcript and is missing from the summary;
        it cannot prove the summary describes it correctly, and no fixture can.
        That is why it reports rather than refuses: a summary that scores badly is
        surfaced to the caller with the numbers behind it, because silently
        dropping a compaction would strand a Conversation that has run out of
        context window.

        An anchor needs a stem of at least two characters, so prose abbreviations
        ("e.g.", "i.e.") are not mistaken for file names, and the anchor list is
        sorted so the same transcript always measures the same way.
    .PARAMETER History
        The history entries that the summary replaces (oldest first).
    .PARAMETER Summary
        The cleaned summary text.
    .PARAMETER MinimumCoverage
        The share of source references a complete summary must carry. Default
        0.6: a summary that names most of the files the Turns worked on is doing
        its job, while one that names almost none has lost the thread.
    .OUTPUTS
        System.Collections.Hashtable with keys sections, missingSections, anchors,
        preserved, missing, coverage and complete.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$History,

        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Summary,

        [double]$MinimumCoverage = 0.6
    )

    $summaryText = [string]$Summary

    $sectionPatterns = [ordered]@{
        goals       = '(?i)\bgoals?\b\s*:'
        constraints = '(?i)\bconstraints?\b\s*:'
        decisions   = '(?i)\bdecisions?\b\s*:'
        unresolved  = '(?i)\b(unresolved|open questions|next steps)\b\s*:'
        references  = '(?i)\b(references|sources|source references|files)\b\s*:'
    }
    $sections = @{}
    $missingSections = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $sectionPatterns.Keys) {
        $present = [bool]($summaryText -match $sectionPatterns[$name])
        $sections[$name] = $present
        if (-not $present) { $missingSections.Add($name) }
    }

    # A source reference is a file-like token: a stem of two or more characters,
    # optional path segments, and a short alphabetic extension.
    $anchorPattern = '(?<![\w.])([A-Za-z0-9_][A-Za-z0-9_\-]+(?:[\\/][A-Za-z0-9_.\-]+)*\.[A-Za-z][A-Za-z0-9]{0,4})(?![\w])'
    $found = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($History)) {
        if ($null -eq $entry) { continue }
        $content = if ($entry -is [System.Collections.IDictionary]) { $entry['content'] }
        else { Get-DpPropertyValue -InputObject $entry -Name @('content', 'Content') -Default '' }
        $text = if ($content -is [string]) { $content } else { [string]($content | ConvertTo-Json -Depth 6 -Compress) }
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        foreach ($match in [regex]::Matches($text, $anchorPattern)) {
            $null = $found.Add($match.Groups[1].Value)
        }
    }

    $anchors = @($found | Sort-Object)
    $preserved = [System.Collections.Generic.List[string]]::new()
    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($anchor in $anchors) {
        if ($summaryText -and $summaryText.IndexOf($anchor, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $preserved.Add($anchor) }
        else { $missing.Add($anchor) }
    }

    $coverage = if ($anchors.Count -eq 0) { 1.0 } else { [Math]::Round($preserved.Count / [double]$anchors.Count, 3) }

    @{
        sections        = $sections
        missingSections = @($missingSections)
        anchors         = $anchors
        preserved       = @($preserved)
        missing         = @($missing)
        coverage        = $coverage
        complete        = (($missingSections.Count -eq 0) -and ($coverage -ge $MinimumCoverage))
    }
}
