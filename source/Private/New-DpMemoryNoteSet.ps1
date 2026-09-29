function New-DpMemoryNoteSet {
    <#
    .SYNOPSIS
        Turns a block of memory text into bounded, attributed Agent Memory notes.
    .DESCRIPTION
        The builder for everything that arrives as text: the Model's answer to a
        memory-extraction Turn, and the user's own edit of a memory scope. One
        non-empty line becomes one note, so the store holds facts rather than
        prose, and every note is stamped with the origin, Project and Conversation
        the CALLER declares - the text itself never gets a say.

        Bounded by construction: each note is truncated to the per-note cap and
        the set is capped at the note count (Get-DpMemoryLimits), so a Model that
        answers with a megabyte of repetition cannot grow the store. Duplicates
        and empty lines are dropped, and a leading list bullet is stripped so the
        recall projection does not render a bullet inside a bullet.

        Truncating rather than throwing is deliberate here: this is the path a
        Model's answer takes, where there is nobody to tell. The API path checks
        the same limits first and rejects an oversized edit explicitly.
    .PARAMETER Text
        The memory text to split into notes.
    .PARAMETER Source
        Who the notes came from: user, learned or legacy.
    .PARAMETER Scope
        Whether the notes are global or bound to one Project.
    .PARAMETER ProjectId
        The Project the notes belong to; required for the project scope.
    .PARAMETER ConversationId
        The Conversation the notes were learned in, when it is known.
    .PARAMETER Confirmed
        The user confirmed these notes; marks them verified.
    .PARAMETER MaxNotes
        An optional lower cap than the store's own note count.
    .OUTPUTS
        System.Object[] of note hashtables.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds and returns in-memory note records; it changes nothing outside the returned value.')]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text,

        [ValidateSet('user', 'learned', 'legacy')]
        [string]$Source = 'learned',

        [ValidateSet('global', 'project')]
        [string]$Scope = 'global',

        [AllowNull()]
        [AllowEmptyString()]
        [string]$ProjectId,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$ConversationId,

        [switch]$Confirmed,

        [int]$MaxNotes = 0
    )

    $limits = Get-DpMemoryLimits
    $cap = $limits.noteCount
    if ($MaxNotes -gt 0 -and $MaxNotes -lt $cap) { $cap = $MaxNotes }

    $notes = [System.Collections.Generic.List[object]]::new()
    if ([string]::IsNullOrWhiteSpace($Text)) { return @($notes) }

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $now = [DateTime]::UtcNow.ToString('o')

    foreach ($line in @($Text -split '\r?\n')) {
        if ($notes.Count -ge $cap) { break }
        $fact = ([string]$line).Trim()
        if (-not $fact) { continue }
        $fact = [regex]::Replace($fact, '^[-*\u2022]\s+', '')
        $fact = ([regex]::Replace($fact, '\s+', ' ')).Trim()
        if (-not $fact) { continue }
        if ($fact.Length -gt $limits.note) { $fact = $fact.Substring(0, $limits.note).TrimEnd() }
        if (-not $seen.Add($fact)) { continue }

        $notes.Add((ConvertTo-DpMemoryNote -InputObject @{
                    text           = $fact
                    source         = $Source
                    scope          = $Scope
                    projectId      = $ProjectId
                    conversationId = $ConversationId
                    createdUtc     = $now
                    updatedUtc     = $now
                } -Confirmed:$Confirmed))
    }

    @($notes)
}
