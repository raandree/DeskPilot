function Resolve-DpApprovalGrant {
    <#
    .SYNOPSIS
        Decides whether an existing grant already authorizes a request.
    .DESCRIPTION
        Returns whether the action may proceed without asking, plus the state to
        keep - an `once` grant is consumed by the action it authorized, so the
        next identical call asks again.

        Every match requires the same Conversation *and* the same Turn, which is
        what makes a stale or cross-Conversation grant inert rather than merely
        unlikely to be reached. `once` additionally requires the exact action
        fingerprint; `turn` matches the Tool class, which is the narrow scope the
        user was offered.
    .PARAMETER State
        The current approval state.
    .PARAMETER Request
        The request being checked.
    .OUTPUTS
        System.Collections.Hashtable with approved and state.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$State,

        [Parameter(Mandatory)]
        [hashtable]$Request
    )

    $kept = [System.Collections.Generic.List[hashtable]]::new()
    $approved = $false

    foreach ($grant in @($State.grants)) {
        if ($approved) { $kept.Add($grant); continue }

        $sameScope = ([string]$grant.class -eq [string]$Request.class) -and
                     ([string]$grant.conversationId -eq [string]$Request.conversationId) -and
                     ([string]$grant.turnId -eq [string]$Request.turnId)
        if (-not $sameScope) { $kept.Add($grant); continue }

        if ([string]$grant.kind -eq 'turn') { $approved = $true; $kept.Add($grant); continue }

        if ([string]$grant.fingerprint -eq [string]$Request.fingerprint) {
            # Consumed: an allow-once grant authorizes one action, not a pattern.
            $approved = $true
            continue
        }
        $kept.Add($grant)
    }

    @{
        approved = $approved
        state    = @{ turnId = [string]$State.turnId; grants = @($kept) }
    }
}
