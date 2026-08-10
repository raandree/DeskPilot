function Switch-DpIntercomAgent {
    <#
    .SYNOPSIS
        Selects the Agent used for the next Turn, or clears the selection.
    .DESCRIPTION
        The one place a remote Agent switch happens, shared by the typed command and
        the tapped button so the two cannot drift apart.

        Selecting an Agent executes nothing - it only decides which *.agent.md body
        becomes the next Turn's -SystemPrompt - so it needs no opted-in Project.
        Settings are read at the start of each Turn, so a switch made while a job is
        running deliberately applies to the next instruction rather than disturbing
        the one in flight; the reply says so.
    .PARAMETER AgentId
        The Agent's id (its *.agent.md file name). An empty value clears the
        selection and returns to the Engine's own default prompt.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Applies an already-authorised remote selection on the accept thread; ShouldProcess is not meaningful there.')]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$AgentId
    )

    $state = $script:DeskPilot

    $agent = $null
    if (-not [string]::IsNullOrWhiteSpace($AgentId)) {
        $agent = @(Get-DpIntercomAgentList) | Where-Object { $_.id -eq $AgentId } | Select-Object -First 1
        if (-not $agent) {
            $null = Send-DpIntercomMessage -Title 'I could not find that one.' -Line @(
                'It may have been renamed or removed. Send /agents for the current list.'
            ) -Kind 'notice'
            return
        }
    }

    try {
        $state.Settings = Merge-DpSettings -Current $state.Settings -Patch @{ selectedAgent = $(if ($agent) { $agent.id } else { $null }) }
    }
    catch {
        $null = Send-DpIntercomMessage -Title 'I could not switch to that agent.' -Line @("$_") -Kind 'notice'
        return
    }
    if ($state.DataDir) { Save-DpSettings -Settings $state.Settings -Directory $state.DataDir }

    if ($agent) {
        $null = Send-DpIntercomMessage -Title 'Switched agent.' -Line @(
            "Agent: $($agent.name)",
            'It takes effect on your next instruction.'
        ) -Kind 'agent'
    }
    else {
        $null = Send-DpIntercomMessage -Title 'Agent cleared.' -Line @(
            'Back to the default agent.',
            'It takes effect on your next instruction.'
        ) -Kind 'agent'
    }
}
