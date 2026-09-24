function Get-DpLearningSource {
    <#
    .SYNOPSIS
        Resolves which Turn a learning request is about, and what it may read.
    .DESCRIPTION
        Learning is asynchronous: the request arrives after the Turn has finished,
        and by then the user may have run another Turn in another Project in the
        same Conversation. So the request names the assistant Message of the Turn
        it is about, and everything else is derived from that Message's own
        immutable Host stamp (see Set-DpMessageProject):

        - the Project the notes belong to is that Message's Project, whatever the
          Conversation has done since;
        - the extraction may read only Messages carrying the SAME Project stamp,
          so one Project's words never reach another Project's notes;
        - and only Messages up to and including that Message, so a later Turn
          cannot leak backwards into an earlier Turn's learning.

        Provenance is required, not inferred. A missing id, an id that no longer
        resolves, a Message that is not an assistant Message, and a Message this
        Host never stamped are all refused: the alternative is guessing which
        Project a fact belongs to, which is the mistake this function exists to
        make impossible.
    .PARAMETER Conversation
        The Conversation the request names.
    .PARAMETER MessageId
        The id of the assistant Message whose Turn is being learned from.
    .PARAMETER MaxMessages
        How many of the Turn's own recent Messages to hand to the extraction.
        Default 8.
    .OUTPUTS
        System.Collections.Hashtable with keys ok, code, message, messageId,
        projectId, scope and messages.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Conversation,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$MessageId,

        [int]$MaxMessages = 8
    )

    $refusal = {
        param([string]$Code, [string]$Text)
        @{ ok = $false; code = $Code; message = $Text; messageId = $MessageId; projectId = $null; scope = 'global'; messages = @() }
    }

    $wanted = ([string]$MessageId).Trim()
    if (-not $wanted) {
        return (& $refusal 'missing_provenance' 'A learning request must name the assistant message of the turn it is about.')
    }

    $all = @($Conversation.messages)
    $index = -1
    for ($i = 0; $i -lt $all.Count; $i++) {
        if ([string](Get-DpPropertyValue -InputObject $all[$i] -Name @('id') -Default '') -ceq $wanted) { $index = $i; break }
    }
    if ($index -lt 0) {
        return (& $refusal 'stale_provenance' 'That turn is no longer part of this conversation.')
    }

    $target = $all[$index]
    if ([string](Get-DpPropertyValue -InputObject $target -Name @('role') -Default '') -ne 'assistant') {
        return (& $refusal 'stale_provenance' 'Learning is bound to the assistant message of a completed turn.')
    }

    # A sentinel rather than $null: an unstamped Message and one stamped with no
    # Project are different facts, and only the second can be learned from.
    $unstamped = [guid]::NewGuid().ToString('N')
    $stamp = Get-DpPropertyValue -InputObject $target -Name @('projectId') -Default $unstamped
    if ($stamp -is [string] -and $stamp -eq $unstamped) {
        return (& $refusal 'stale_provenance' 'DeskPilot did not record which project that turn ran in, so it cannot file what the turn taught.')
    }
    $projectId = ([string]$stamp).Trim()

    $sameScope = {
        param($candidate)
        $role = [string](Get-DpPropertyValue -InputObject $candidate -Name @('role') -Default '')
        if ($role -notin @('user', 'assistant')) { return $false }
        $candidateStamp = Get-DpPropertyValue -InputObject $candidate -Name @('projectId') -Default $unstamped
        if ($candidateStamp -is [string] -and $candidateStamp -eq $unstamped) { return $false }
        ([string]$candidateStamp).Trim() -eq $projectId
    }

    $window = @($all[0..$index] | Where-Object { & $sameScope $_ } | Select-Object -Last $MaxMessages)
    if ($window.Count -lt 2) {
        return (& $refusal 'too_short' 'That turn is too short to learn from.')
    }

    @{
        ok        = $true
        code      = ''
        message   = ''
        messageId = $wanted
        projectId = $(if ($projectId) { $projectId } else { $null })
        scope     = $(if ($projectId) { 'project' } else { 'global' })
        messages  = $window
    }
}
