function Test-DpConversationWritable {
    <#
    .SYNOPSIS
        Reports whether a Turn may run against a Conversation.
    .DESCRIPTION
        One rule for every entry point, because Intercom and the window both had
        their own gap: a Conversation deleted while Intercom was bound to it fell
        through to "the most recent one" and quietly did the work somewhere else,
        and an archived Conversation accepted new Turns as though it had never
        been put away.

        Archiving is the user saying "I am done with this". Silently continuing to
        write into it - or into a neighbour - is worse than refusing.
    .PARAMETER Conversation
        The Conversation to check, or $null when it no longer exists.
    .OUTPUTS
        System.Collections.Hashtable with ok, code and reason.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]
        [object]$Conversation
    )

    if ($null -eq $Conversation) {
        return @{ ok = $false; code = 'conversation_missing'; reason = 'That conversation no longer exists.' }
    }

    if ([bool](Get-DpPropertyValue -InputObject $Conversation -Name @('archived') -Default $false)) {
        $title = [string](Get-DpPropertyValue -InputObject $Conversation -Name @('title') -Default 'That conversation')
        return @{ ok = $false; code = 'conversation_archived'; reason = "'$title' is archived. Unarchive it before working in it again." }
    }

    @{ ok = $true; code = ''; reason = '' }
}
