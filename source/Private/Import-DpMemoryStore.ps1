function Import-DpMemoryStore {
    <#
    .SYNOPSIS
        Loads the persisted Agent Memory store from disk.
    .DESCRIPTION
        Reads agent-memory.json from the given directory and returns the canonical
        store (see New-DpMemoryStore): attributed notes, the version-1 text
        projection, the store timestamp, and why the file could not be read in
        full when it could not.

        Version 1 - a single text blob with a timestamp - is migrated without
        loss: the whole blob becomes one note marked legacy and unverified, with
        no Project, no Conversation and no invented creation date. It stays
        globally recalled, because that is what it always was; it is simply now
        labelled as what DeskPilot actually knows about it, which is nothing.

        A file this version cannot read is reported rather than swallowed. The
        caller still gets a usable empty store so the Host starts, the problem
        travels on the store as loadError so the UI can say so, and the file
        itself is left on disk - Save-DpMemoryStore keeps a backup of it before
        anything replaces it. A future version's file is read for its version-1
        text only, which is the one field whose meaning is guaranteed.
    .PARAMETER Directory
        The data directory to read from.
    .OUTPUTS
        System.Collections.Hashtable - the Agent Memory store.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Directory
    )

    $path = Join-Path $Directory 'agent-memory.json'
    if (-not (Test-Path -LiteralPath $path)) { return (New-DpMemoryStore -Note @()) }

    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return (New-DpMemoryStore -Note @()) }
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop

        $text = [string](Get-DpPropertyValue -InputObject $parsed -Name @('text', 'Text') -Default '')
        # ConvertFrom-Json coerces an ISO timestamp string into a [DateTime], which
        # [string] would then reformat in the current culture; normalise it back to
        # a round-trippable ISO-8601 UTC string (as the conversation/usage stores do).
        $updated = ConvertTo-DpIsoString -Value (Get-DpPropertyValue -InputObject $parsed -Name @('updatedUtc', 'UpdatedUtc') -Default $null)
        $version = [int](Get-DpPropertyValue -InputObject $parsed -Name @('version', 'Version') -Default 1)

        if ($version -gt 2) {
            $message = "Agent memory was written by a newer version of DeskPilot (file version $version); only its plain-text notes were read, and the file is kept as a backup before anything replaces it."
            Write-Error $message
            return (New-DpMemoryStore -Text $text -UpdatedUtc $updated -LoadError $message)
        }

        if ($version -lt 2) { return (New-DpMemoryStore -Text $text -UpdatedUtc $updated) }

        $notes = [System.Collections.Generic.List[object]]::new()
        $dropped = 0
        foreach ($entry in @(Get-DpPropertyValue -InputObject $parsed -Name @('notes', 'Notes') -Default @())) {
            try { $notes.Add((ConvertTo-DpMemoryNote -InputObject $entry -FromStore)) }
            catch {
                $noteError = $_
                Write-Verbose "Skipped an unreadable agent memory note: $noteError"
                $dropped++
            }
        }
        $limits = Get-DpMemoryLimits
        if ($notes.Count -gt $limits.noteCount) { $dropped += ($notes.Count - $limits.noteCount) }

        $loadError = $null
        if ($dropped -gt 0) {
            $loadError = "$dropped saved memory note(s) could not be read and were left out; the previous file is kept as a backup before memory is next saved."
            Write-Error $loadError
        }

        return (New-DpMemoryStore -Note @($notes) -UpdatedUtc $updated -LoadError $loadError)
    }
    catch {
        $message = "Failed to load agent memory (starting empty and keeping the file): $_"
        Write-Error $message
        return (New-DpMemoryStore -Note @() -LoadError $message)
    }
}
