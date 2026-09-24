function Get-DpMemoryRecall {
    <#
    .SYNOPSIS
        Projects the Agent Memory into the notes one Turn may actually see.
    .DESCRIPTION
        Recall is scoped: the global notes, plus the notes learned in the Project
        this Turn runs in, and nothing else. A note learned while working on one
        Project is not a fact about another, and replaying it there is both a
        privacy leak between a user's clients and a reliable way to make the agent
        confidently wrong.

        Every note is rendered with the provenance DeskPilot recorded in front of
        its text - who it came from and whether anyone has verified it - so the
        Model can weigh a fact the user stated against one the agent inferred.
        The tag is written by the Host and a note is stored on one line, so a
        note's own text cannot masquerade as a tag. This is reference data: it is
        fenced as background by New-DpTurnParameter and grants nothing.

        A legacy blob has no origin and no date, so it is rendered as exactly
        that: an indented quotation, labelled unverified, with nothing invented
        around it.

        The projection is capped (Agent Memory limit) with the least trustworthy
        notes dropped first, and reports what it dropped rather than pretending
        the Model saw everything.
    .PARAMETER Store
        The Agent Memory store (see New-DpMemoryStore).
    .PARAMETER ProjectId
        The Project the Turn is running in, or $null when none is selected.
    .PARAMETER ProjectName
        The Project's display name, used in the tag when it is known.
    .PARAMETER MaxChars
        The character cap for the projection. Defaults to the Agent Memory limit.
    .OUTPUTS
        System.Collections.Hashtable with keys text, notes, included, excluded and
        truncated.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]
        [object]$Store,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$ProjectId,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$ProjectName,

        [int]$MaxChars = 0
    )

    if ($MaxChars -le 0) { $MaxChars = (Get-DpMemoryLimits).agentMemory }

    $empty = @{ text = ''; notes = @(); included = 0; excluded = 0; truncated = $false }
    if ($null -eq $Store) { return $empty }
    $all = @(Get-DpPropertyValue -InputObject $Store -Name @('notes', 'Notes') -Default @())
    if ($all.Count -eq 0) {
        # A store that still holds only version-1 text (an older caller, or a test
        # fixture) is recalled as what it is rather than as nothing at all.
        $blob = [string](Get-DpPropertyValue -InputObject $Store -Name @('text', 'Text') -Default '')
        if ([string]::IsNullOrWhiteSpace($blob)) { return $empty }
        $all = @((New-DpMemoryStore -Text $blob).notes)
    }
    if ($all.Count -eq 0) { return $empty }

    $visible = @($all | Where-Object {
            $_ -and ($_.scope -ne 'project' -or ($ProjectId -and $_.projectId -eq $ProjectId))
        })
    if ($visible.Count -eq 0) { return $empty }

    # Most trustworthy first, so a cap drops the weakest evidence rather than the
    # user's own words.
    $rank = { param($note) switch ($note.source) { 'user' { 0 } 'learned' { 1 } default { 2 } } }
    $ordered = @($visible | Sort-Object -Stable -Property @{ Expression = { & $rank $_ } })

    $projectLabel = if ($ProjectName) { "in $ProjectName" } else { 'in this Project' }
    $lines = [System.Collections.Generic.List[string]]::new()
    $kept = [System.Collections.Generic.List[object]]::new()
    $length = 0
    $excluded = 0

    foreach ($note in $ordered) {
        $block = if ($note.source -eq 'legacy') {
            $quoted = (@($note.text -split '\r?\n') | ForEach-Object { '  ' + $_ }) -join "`n"
            "Carried over from an earlier version of DeskPilot; origin and date unknown, not verified:`n$quoted"
        }
        else {
            $tag = switch ($note.source) {
                'user' { if ($note.scope -eq 'project') { "from the user, $projectLabel" } else { 'from the user' } }
                default {
                    $where = if ($note.scope -eq 'project') { "learned $projectLabel" } else { 'learned in an earlier conversation' }
                    if ($note.verified) { "$where, confirmed by the user" } else { "$where, not verified" }
                }
            }
            "- ($tag) $($note.text)"
        }

        $cost = $block.Length + $(if ($lines.Count -gt 0) { 1 } else { 0 })
        if (($length + $cost) -gt $MaxChars) { $excluded++; continue }
        $lines.Add($block)
        $kept.Add($note)
        $length += $cost
    }

    @{
        text      = ($lines -join "`n")
        notes     = @($kept)
        included  = $kept.Count
        excluded  = $excluded
        truncated = ($excluded -gt 0)
    }
}
