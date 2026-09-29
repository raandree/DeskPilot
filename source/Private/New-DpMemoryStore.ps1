function New-DpMemoryStore {
    <#
    .SYNOPSIS
        Builds the canonical in-memory Agent Memory store from notes or from
        version-1 text.
    .DESCRIPTION
        One shape for the whole Host: the structured notes, the version-1 text
        projection an existing client still reads and edits, the store timestamp,
        and any problem the load hit. Building it in one place is what keeps the
        projection from drifting away from the notes it is meant to project.

        The text projection is the GLOBAL scope only, and deliberately so. It is
        the view a client that knows nothing about scopes shows in a textarea and
        writes straight back; if it carried a Project's notes, saving that box
        would silently promote them to everywhere. Project notes are reached
        through the notes list instead.

        -Text is the version-1 shape: the whole blob becomes one legacy note,
        migrated as it stands. Splitting it into facts would invent a structure
        the user never wrote, and tagging those facts would invent provenance.

        Bounds are a refusal, not a trim. A mutation that would not fit - more
        notes than the store holds, or global notes larger than what is recalled
        into a Turn - throws, so the caller answers the user instead of quietly
        dropping whichever notes happened to be last in the list. Only a loader
        passes -Truncate, because a file that is already too big has to be opened
        somehow; it then projects a bounded subset AND says what it left out, so
        the store is marked lossy and Save-DpMemoryStore keeps the original bytes
        before replacing them.
    .PARAMETER Note
        The notes to hold. Normalised through ConvertTo-DpMemoryNote -FromStore,
        so verification already recorded by this Host is preserved.
    .PARAMETER Text
        A version-1 Agent Memory blob to migrate into a single legacy note.
    .PARAMETER UpdatedUtc
        The store timestamp; defaults to the newest note timestamp, else unknown.
    .PARAMETER LoadError
        Why the persisted store could not be read in full, when it could not.
    .PARAMETER Truncate
        For a loader only: bound what does not fit instead of refusing it, and
        report the loss on loadError.
    .OUTPUTS
        System.Collections.Hashtable with keys version, notes, text, updatedUtc
        and loadError.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Notes')]
    [OutputType([hashtable])]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs and returns an in-memory store record; persistence is Save-DpMemoryStore.')]
    param(
        [Parameter(ParameterSetName = 'Notes')]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Note = @(),

        [Parameter(ParameterSetName = 'Text', Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text,

        [AllowNull()]
        [object]$UpdatedUtc,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$LoadError,

        [switch]$Truncate
    )

    $limits = Get-DpMemoryLimits
    $notes = [System.Collections.Generic.List[object]]::new()
    $losses = [System.Collections.Generic.List[string]]::new()
    if ($LoadError) { $losses.Add($LoadError) }

    if ($PSCmdlet.ParameterSetName -eq 'Text') {
        $blob = ([string]$Text).Trim()
        if ($blob.Length -gt $limits.agentMemory) {
            if (-not $Truncate) {
                throw "Agent memory holds at most $($limits.agentMemory) characters of notes; this text is $($blob.Length). Shorten it first."
            }
            # A version-1 blob longer than the cap loses its tail. Saying so is
            # what makes the next save keep the original file instead of making
            # the loss permanent.
            $losses.Add("$($blob.Length - $limits.agentMemory) character(s) of the previous plain-text memory did not fit and were left out.")
            $blob = $blob.Substring(0, $limits.agentMemory)
        }
        if ($blob) {
            $notes.Add((ConvertTo-DpMemoryNote -InputObject @{
                        text       = $blob
                        source     = 'legacy'
                        scope      = 'global'
                        updatedUtc = $UpdatedUtc
                    } -FromStore))
        }
    }
    else {
        foreach ($entry in @($Note)) {
            if ($null -eq $entry) { continue }
            $notes.Add((ConvertTo-DpMemoryNote -InputObject $entry -FromStore))
        }
        if ($notes.Count -gt $limits.noteCount) {
            if (-not $Truncate) {
                throw "Agent memory holds at most $($limits.noteCount) notes and this change would make $($notes.Count). Forget some notes in Settings > Memory first."
            }
            $losses.Add("$($notes.Count - $limits.noteCount) saved note(s) beyond the $($limits.noteCount)-note limit were left out.")
            $notes = [System.Collections.Generic.List[object]]::new(@($notes | Select-Object -First $limits.noteCount))
        }
    }

    $globalText = (@($notes | Where-Object { $_.scope -eq 'global' } | ForEach-Object { $_.text }) -join "`n")
    if ($globalText.Length -gt $limits.agentMemory) {
        if (-not $Truncate) {
            throw "The notes that apply to every project must fit $($limits.agentMemory) characters and would be $($globalText.Length). Forget or shorten some notes in Settings > Memory first."
        }
        $losses.Add("$($globalText.Length - $limits.agentMemory) character(s) of the notes that apply to every project did not fit and were left out.")
        $globalText = $globalText.Substring(0, $limits.agentMemory)
    }

    $stamp = ConvertTo-DpIsoString -Value $UpdatedUtc
    if (-not $stamp) {
        $stamp = @($notes | ForEach-Object { $_.updatedUtc } | Where-Object { $_ } | Sort-Object) | Select-Object -Last 1
    }

    @{
        version    = 2
        notes      = @($notes)
        text       = $globalText
        updatedUtc = $(if ($stamp) { $stamp } else { $null })
        loadError  = $(if ($losses.Count -gt 0) { $losses -join ' ' } else { $null })
    }
}
