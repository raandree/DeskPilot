function Add-DpApprovalGrant {
    <#
    .SYNOPSIS
        Records what the user just authorized.
    .DESCRIPTION
        Returns a new state; the input is never mutated. A grant stores the
        fingerprint and the class, never the command - the fingerprint is a
        digest, so a grant that outlives the request cannot disclose what was run.

        Scope is deliberately coarse in only one direction: `turn` covers the Tool
        class for the rest of this Turn, `once` covers exactly the action that was
        shown. Neither ever becomes a persistent policy, because the state itself
        is discarded when the Turn ends.
    .PARAMETER State
        The current approval state.
    .PARAMETER Request
        The request the user answered.
    .PARAMETER Scope
        once or turn.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$State,

        [Parameter(Mandatory)]
        [hashtable]$Request,

        [Parameter(Mandatory)]
        [ValidateSet('once', 'turn')]
        [string]$Scope
    )

    $grant = @{
        kind           = $Scope
        class          = [string]$Request.class
        fingerprint    = [string]$Request.fingerprint
        conversationId = [string]$Request.conversationId
        turnId         = [string]$Request.turnId
        grantedUtc     = [datetime]::UtcNow.ToString('o')
    }

    @{ turnId = [string]$State.turnId; grants = @(@($State.grants) + $grant) }
}
