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
    .PARAMETER Note
        The notes to hold. Normalised through ConvertTo-DpMemoryNote -FromStore,
        so verification already recorded by this Host is preserved.
    .PARAMETER Text
        A version-1 Agent Memory blob to migrate into a single legacy note.
    .PARAMETER UpdatedUtc
        The store timestamp; defaults to the newest note timestamp, else unknown.
    .PARAMETER LoadError
        Why the persisted store could not be read in full, when it could not.
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
        [string]$LoadError
    )

    $limits = Get-DpMemoryLimits
    $notes = [System.Collections.Generic.List[object]]::new()

    if ($PSCmdlet.ParameterSetName -eq 'Text') {
        $blob = ([string]$Text).Trim()
        if ($blob.Length -gt $limits.agentMemory) { $blob = $blob.Substring(0, $limits.agentMemory) }
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
            if ($notes.Count -ge $limits.noteCount) { break }
            $notes.Add((ConvertTo-DpMemoryNote -InputObject $entry -FromStore))
        }
    }

    $globalText = (@($notes | Where-Object { $_.scope -eq 'global' } | ForEach-Object { $_.text }) -join "`n")
    if ($globalText.Length -gt $limits.agentMemory) { $globalText = $globalText.Substring(0, $limits.agentMemory) }

    $stamp = ConvertTo-DpIsoString -Value $UpdatedUtc
    if (-not $stamp) {
        $stamp = @($notes | ForEach-Object { $_.updatedUtc } | Where-Object { $_ } | Sort-Object) | Select-Object -Last 1
    }

    @{
        version    = 2
        notes      = @($notes)
        text       = $globalText
        updatedUtc = $(if ($stamp) { $stamp } else { $null })
        loadError  = $(if ($LoadError) { $LoadError } else { $null })
    }
}
