function Switch-DpIntercomModel {
    <#
    .SYNOPSIS
        Selects the Model used for the next Turn, or returns to the default one.
    .DESCRIPTION
        The one place a remote Model switch happens, shared by the typed command and
        the tapped button so the two cannot drift apart.

        Selecting a Model executes nothing - it only decides which Model the next
        Turn runs on - so it needs no opted-in Project.

        Two writes, not one. Settings holds the default Model, but Invoke-DpTurn
        prefers a Conversation's own pin, and New-DpConversation pins whatever the
        Settings default was at the time. Writing only Settings would therefore be a
        silent no-op for exactly the Conversation the operator is talking to, and
        the reply would name a Model the next instruction was never going to use.
    .PARAMETER ModelId
        The Model id to use. An empty value clears both the Settings default and the
        bound Conversation's pin, so DeskPilot's own default applies again.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Applies an already-authorised remote selection on the accept thread; ShouldProcess is not meaningful there.')]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$ModelId
    )

    $state = $script:DeskPilot

    if (-not [string]::IsNullOrWhiteSpace($ModelId)) {
        $known = @(Get-DpIntercomModelList) | Where-Object { $_.id -eq $ModelId } | Select-Object -First 1
        if (-not $known) {
            $null = Send-DpIntercomMessage -Title 'I could not find that one.' -Line @(
                'Your account may no longer be offered it. Send /models for the current list.'
            ) -Kind 'notice'
            return
        }
    }

    $target = if ([string]::IsNullOrWhiteSpace($ModelId)) { $null } else { $ModelId }

    try {
        $state.Settings = Merge-DpSettings -Current $state.Settings -Patch @{ model = $target }
    }
    catch {
        $null = Send-DpIntercomMessage -Title 'I could not switch to that model.' -Line @("$_") -Kind 'notice'
        return
    }
    if ($state.DataDir) { Save-DpSettings -Settings $state.Settings -Directory $state.DataDir }

    # The bound Conversation's pin outranks the Settings default, so it has to move
    # too or the very next instruction would still run on the old Model.
    $conversationId = [string](Get-DpPropertyValue -InputObject $state.Intercom -Name @('ConversationId') -Default '')
    if ($conversationId) {
        $conversation = $state.Conversations[$conversationId]
        if ($conversation) {
            $conversation.model = $target
            if ($state.DataDir) { Save-DpConversationStore -Store $state.Conversations -Directory $state.DataDir }
        }
    }

    if ($target) {
        $null = Send-DpIntercomMessage -Title 'Switched model.' -Line @(
            "Model: $target",
            'It takes effect on your next instruction.'
        ) -Kind 'model'
    }
    else {
        $fallback = [string](Get-DpPropertyValue -InputObject $state -Name @('DefaultModel') -Default '')
        $null = Send-DpIntercomMessage -Title 'Model cleared.' -Line @(
            "Back to the standard model$(if ($fallback) { ": $fallback" }).",
            'It takes effect on your next instruction.'
        ) -Kind 'model'
    }
}
