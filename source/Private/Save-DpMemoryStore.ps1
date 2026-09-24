function Save-DpMemoryStore {
    <#
    .SYNOPSIS
        Persists the Agent Memory store to disk as JSON.
    .DESCRIPTION
        Writes the store to agent-memory.json in the given directory as version 2:
        the attributed notes, plus the version-1 text and updatedUtc fields so a
        downgraded or older DeskPilot still finds the global notes where it has
        always looked for them. Atomic (temp file then move) and best-effort: a
        failure is written to the error stream but not thrown, matching the other
        DeskPilot stores.

        A store this version cannot read IN FULL is never lost. Before replacing
        the file, it is loaded again through Import-DpMemoryStore and kept if that
        load reports any loss - which is the only way the two can agree on what
        "lossy" means. A file that parses as JSON but holds notes this version
        refuses counts exactly like one that does not parse at all: both had
        content that the file about to be written no longer contains.

        The kept copy is a COPY, named after the full SHA-256 of its bytes, and it
        never clobbers an existing file: the copy itself uses create-new semantics
        (Copy-DpPreservedFile), so a name taken between the check and the write
        cannot be overwritten either. If no copy can be made, the save fails and
        the original stays exactly where it is - a store is never replaced by
        something that was not preserved first. The original is only replaced once
        the new content has been written successfully, so a save that fails is not
        the thing that loses the data.

        A plain { text; updatedUtc } hashtable is still accepted and saved as a
        migrated legacy note, so an older caller keeps working.
    .PARAMETER Memory
        The memory store (or a version-1 { text; updatedUtc } hashtable) to save.
    .PARAMETER Directory
        The data directory to write into.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Memory,

        [Parameter(Mandatory)]
        [string]$Directory
    )

    try {
        if (-not (Test-Path -LiteralPath $Directory)) {
            New-Item -ItemType Directory -Path $Directory -Force -ErrorAction Stop | Out-Null
        }

        $storeUpdatedUtc = Get-DpPropertyValue -InputObject $Memory -Name @('updatedUtc') -Default $null
        $store = if ($Memory.ContainsKey('notes')) {
            # Strict: a note set that does not fit is a caller bug, and trimming it
            # here would lose notes behind a successful-looking save. The memory
            # routes refuse an over-cap change before it ever reaches this point.
            New-DpMemoryStore -Note @($Memory.notes) -UpdatedUtc $storeUpdatedUtc -LoadError ([string](Get-DpPropertyValue -InputObject $Memory -Name @('loadError') -Default ''))
        }
        else {
            # The version-1 compatibility shim, whose documented behaviour has
            # always been to cap on save. The capping is reported on the store, and
            # whatever is on disk is preserved by the lossy check below.
            New-DpMemoryStore -Text ([string](Get-DpPropertyValue -InputObject $Memory -Name @('text') -Default '')) -UpdatedUtc $storeUpdatedUtc -Truncate
        }

        $target = Join-Path $Directory 'agent-memory.json'
        $temp = "$target.tmp"

        $payload = @{
            # Version 1 fields, still first-class: an older client reads the global
            # notes from here and can write them straight back.
            text       = [string]$store.text
            updatedUtc = $store.updatedUtc
            version    = 2
            notes      = @($store.notes)
        } | ConvertTo-Json -Depth 6 -Compress

        # Write the replacement first. Until this succeeds nothing on disk has been
        # touched, so a serialisation or disk failure costs nothing.
        [System.IO.File]::WriteAllText($temp, $payload, [System.Text.UTF8Encoding]::new($false))

        # Would replacing the current file lose anything? Ask the loader, so this
        # decision cannot drift away from what loading actually does.
        if (Test-Path -LiteralPath $target) {
            $existing = Import-DpMemoryStore -Directory $Directory -ErrorAction SilentlyContinue 2>$null
            if ($existing -and $existing.loadError) {
                $hash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
                # Copy, not move: the original stays in place until the new content
                # is safely written over it. And a copy that cannot be made without
                # overwriting somebody else's file throws, which leaves the original
                # exactly where it is - never replaced by something that was not
                # preserved first.
                $preserved = Copy-DpPreservedFile -Path $target -Directory $Directory -Name "agent-memory.$hash.bak"
                if ($preserved.created) {
                    # A warning, not an error: the point is to preserve the file and
                    # carry on saving. What the user is told travels on the store's
                    # loadError, which the memory route answers with.
                    Write-Warning "Some of the previous agent memory could not be read; the file was kept as '$($preserved.path)'."
                }
            }
        }

        Move-Item -LiteralPath $temp -Destination $target -Force -ErrorAction Stop
    }
    catch {
        Write-Error "Failed to persist agent memory: $_"
    }
}
