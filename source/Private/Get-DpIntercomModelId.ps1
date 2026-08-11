function Get-DpIntercomModelId {
    <#
    .SYNOPSIS
        Returns the Model id the next Intercom Turn would run on.
    .DESCRIPTION
        One source for the Model /status reports and the one /models marks as
        current, so the two can never disagree about the same fact.

        The resolution order is Invoke-DpTurn's: the bound Conversation's pin wins,
        then the Settings default, then DeskPilot's own default. Reading only
        Settings would name a Model the Turn is not going to use.
    .OUTPUTS
        System.String - the id, or an empty string when none is resolvable yet.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $state = $script:DeskPilot

    $conversationId = [string](Get-DpPropertyValue -InputObject $state.Intercom -Name @('ConversationId') -Default '')
    if ($conversationId) {
        $conversation = $state.Conversations[$conversationId]
        $pinned = [string](Get-DpPropertyValue -InputObject $conversation -Name @('model') -Default '')
        if ($pinned) { return $pinned }
    }

    $configured = [string](Get-DpPropertyValue -InputObject $state.Settings -Name @('model') -Default '')
    if ($configured) { return $configured }

    [string](Get-DpPropertyValue -InputObject $state -Name @('DefaultModel') -Default '')
}
