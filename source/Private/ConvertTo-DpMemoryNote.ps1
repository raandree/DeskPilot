function ConvertTo-DpMemoryNote {
    <#
    .SYNOPSIS
        Normalises one Agent Memory note into DeskPilot's canonical record.
    .DESCRIPTION
        A note is a single durable fact plus the provenance DeskPilot can actually
        vouch for: where it came from (the user, the agent's own learning, or an
        older version's untagged blob), which Project and Conversation it was
        learned in, when it was written, and whether a human has confirmed it.

        The trust fields are Host-owned. source is validated against a closed set
        and verification is DERIVED, never read from the caller: the user's own
        text is verified, everything a Model produced is not, and only the Host
        can mark a learned note confirmed (-Confirmed) when the user says so in
        the UI. A Model that writes "verified: true" into its answer therefore
        changes nothing. -FromStore is the one exception and is for DeskPilot's
        own file: a store written by this Host keeps the verification it recorded.

        An invalid mutation throws rather than being quietly repaired, because the
        API path can still tell the user; the only value invented for a record
        with no stated origin is 'legacy', which is a statement that the origin is
        unknown rather than a claim about it.

        A user or learned note is collapsed to one line so its own text cannot
        forge the provenance tag the recall projection writes in front of it. A
        legacy note keeps its line breaks: it is an older version's whole blob,
        migrated as it stands rather than split into facts nobody wrote.
    .PARAMETER InputObject
        The note-like object (hashtable or PSCustomObject) to normalise.
    .PARAMETER Confirmed
        The user confirmed this note in the UI. Marks it verified while leaving
        its origin intact.
    .PARAMETER FromStore
        The record came from DeskPilot's own persisted store, so its recorded
        verification is honoured instead of being re-derived.
    .OUTPUTS
        System.Collections.Hashtable with keys id, text, source, scope, projectId,
        conversationId, createdUtc, updatedUtc and verified.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$InputObject,

        [switch]$Confirmed,

        [switch]$FromStore
    )

    if ($null -eq $InputObject) { throw 'A memory note needs text.' }

    $limits = Get-DpMemoryLimits
    $knownSources = @('user', 'learned', 'legacy')
    $knownScopes = @('global', 'project')

    $source = ([string](Get-DpPropertyValue -InputObject $InputObject -Name @('source', 'Source') -Default '')).Trim().ToLowerInvariant()
    # No stated origin means an older or hand-edited record: call it legacy rather
    # than inventing a provenance nobody recorded.
    if (-not $source) { $source = 'legacy' }
    if ($knownSources -notcontains $source) {
        throw "'$source' is not a memory source DeskPilot knows. Allowed: $($knownSources -join ', ')."
    }

    $text = [string](Get-DpPropertyValue -InputObject $InputObject -Name @('text', 'Text') -Default '')
    $text = if ($source -eq 'legacy') { $text.Trim() } else { ([regex]::Replace($text, '\s+', ' ')).Trim() }
    if (-not $text) { throw 'A memory note needs text.' }
    $cap = if ($source -eq 'legacy') { $limits.agentMemory } else { $limits.note }
    if ($text.Length -gt $cap) { throw "A memory note must be $cap characters or fewer." }

    $scope = ([string](Get-DpPropertyValue -InputObject $InputObject -Name @('scope', 'Scope') -Default '')).Trim().ToLowerInvariant()
    if (-not $scope) { $scope = 'global' }
    if ($knownScopes -notcontains $scope) {
        throw "'$scope' is not a memory scope DeskPilot knows. Allowed: $($knownScopes -join ', ')."
    }

    $projectId = ([string](Get-DpPropertyValue -InputObject $InputObject -Name @('projectId', 'ProjectId') -Default '')).Trim()
    if ($scope -eq 'project' -and -not $projectId) {
        throw 'A Project-scoped memory note must name the Project it belongs to.'
    }
    # A global note carries no Project id at all, so a scope change can never
    # leave a stale binding behind for the recall projection to match on.
    if ($scope -eq 'global') { $projectId = $null }

    $conversationId = ([string](Get-DpPropertyValue -InputObject $InputObject -Name @('conversationId', 'ConversationId') -Default '')).Trim()
    if (-not $conversationId) { $conversationId = $null }

    $id = ([string](Get-DpPropertyValue -InputObject $InputObject -Name @('id', 'Id') -Default '')).Trim()
    if (-not $id) { $id = New-DpId -Prefix 'n' }

    # An unknown timestamp stays unknown. A migrated legacy note has no honest
    # creation date, and stamping "now" on it would claim the agent learned it
    # today.
    $createdUtc = ConvertTo-DpIsoString -Value (Get-DpPropertyValue -InputObject $InputObject -Name @('createdUtc', 'CreatedUtc') -Default $null)
    $updatedUtc = ConvertTo-DpIsoString -Value (Get-DpPropertyValue -InputObject $InputObject -Name @('updatedUtc', 'UpdatedUtc') -Default $null)

    $verified = ($source -eq 'user') -or $Confirmed.IsPresent
    if (-not $verified -and $FromStore) {
        # Only a real boolean counts. [bool]'false' is $true in PowerShell, so
        # coercing a stored string would promote an unverified note to a verified
        # one - the one direction this field must never move on its own. A
        # malformed value is refused so the loader can report it and keep the file.
        $claim = Get-DpPropertyValue -InputObject $InputObject -Name @('verified', 'Verified') -Default $null
        if ($null -ne $claim) {
            if ($claim -isnot [bool]) {
                throw "A memory note's verification must be true or false, not '$claim'."
            }
            $verified = [bool]$claim
        }
    }

    @{
        id             = $id
        text           = $text
        source         = $source
        scope          = $scope
        projectId      = $(if ($projectId) { $projectId } else { $null })
        conversationId = $conversationId
        createdUtc     = $(if ($createdUtc) { $createdUtc } else { $null })
        updatedUtc     = $(if ($updatedUtc) { $updatedUtc } else { $null })
        verified       = $verified
    }
}
