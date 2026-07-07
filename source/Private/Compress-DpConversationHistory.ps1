function Compress-DpConversationHistory {
    <#
    .SYNOPSIS
        Rebuilds a Conversation history with older entries replaced by a summary.
    .DESCRIPTION
        Produces a compacted copy of the Engine -History: a two-entry summary
        preamble (a user cue plus the assistant summary) followed by the last
        KeepCount entries kept verbatim, so a subsequent Turn replays far fewer
        tokens while retaining recent detail. The input is never mutated. When the
        summary is empty or the history is already at or below KeepCount + 1
        entries there is nothing worth compacting, so the original entries are
        returned unchanged with changed = $false.
    .PARAMETER History
        The Conversation history entries (oldest first).
    .PARAMETER Summary
        The summary text that replaces the summarised entries.
    .PARAMETER KeepCount
        How many of the most recent entries to keep verbatim. Default 4.
    .OUTPUTS
        System.Collections.Hashtable with keys history, summarised, kept, before,
        after and changed.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$History,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Summary,

        [int]$KeepCount = 4
    )

    $all = @(@($History) | Where-Object { $null -ne $_ })
    if ($KeepCount -lt 0) { $KeepCount = 0 }

    if ([string]::IsNullOrWhiteSpace($Summary) -or $all.Count -le ($KeepCount + 1)) {
        return @{
            history    = $all
            summarised = 0
            kept       = $all.Count
            before     = $all.Count
            after      = $all.Count
            changed    = $false
        }
    }

    $keep = if ($KeepCount -gt 0) { @($all[($all.Count - $KeepCount)..($all.Count - 1)]) } else { @() }
    $summarised = $all.Count - $keep.Count

    $newHistory = [System.Collections.Generic.List[object]]::new()
    $newHistory.Add(@{ role = 'user'; content = 'Summary of the earlier part of this conversation, for context:' })
    $newHistory.Add(@{ role = 'assistant'; content = $Summary })
    foreach ($entry in $keep) { $newHistory.Add($entry) }

    @{
        history    = $newHistory
        summarised = $summarised
        kept       = $keep.Count
        before     = $all.Count
        after      = $newHistory.Count
        changed    = $true
    }
}
