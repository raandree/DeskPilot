function New-DpApprovalState {
    <#
    .SYNOPSIS
        Creates the empty approval state for one Turn.
    .DESCRIPTION
        Approval grants are Turn-scoped by construction: a new Turn gets a new
        state with no grants, so "allow for this Turn" cannot survive into the
        next one by being forgotten about.
    .PARAMETER TurnId
        The Turn the grants will belong to.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$TurnId
    )

    @{ turnId = $TurnId; grants = @() }
}
