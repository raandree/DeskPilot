function Set-DpMessageProject {
    <#
    .SYNOPSIS
        Stamps the Project a Turn ran in onto one of its Messages.
    .DESCRIPTION
        Provenance has to be immutable, and a Conversation is not. One thread can
        be used in one Project and then another, so a single Project field on the
        Conversation is overwritten by every Turn: learning started for the first
        Turn would be filed against the second, and the extraction would read
        Messages from both. A Message, once written, never changes - so the Project
        is recorded there, by the Host, at the moment the Message is created.

        The stamp is always written, including when no Project is selected. An
        absent key and a null value then mean different things: never stamped (a
        Message from an older DeskPilot, or from a surface that does not stamp),
        versus stamped as belonging to no Project. Learning refuses the first and
        accepts the second, rather than guessing which Project an unstamped
        Message came from.
    .PARAMETER Message
        The Message record to stamp. Mutated in place.
    .PARAMETER Settings
        The Settings this Turn runs under (already scoped, if it is scoped).
    #>
    [CmdletBinding()]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Stamps an in-memory Message record as it is created on the Turn thread; ShouldProcess is not meaningful there.')]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Message,

        [Parameter(Mandatory)]
        [AllowNull()]
        [hashtable]$Settings
    )

    $projectId = if ($Settings) { ([string]$Settings.selectedProjectId).Trim() } else { '' }
    $Message.projectId = $(if ($projectId) { $projectId } else { $null })
}
