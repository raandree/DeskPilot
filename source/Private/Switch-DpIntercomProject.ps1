function Switch-DpIntercomProject {
    <#
    .SYNOPSIS
        Selects a registered Project from the phone and reports what that means.
    .DESCRIPTION
        The one place a remote Project switch happens, so the typed command and the
        tapped button cannot drift apart - the same reason both answer routes go
        through Submit-DpIntercomAnswer.

        Switching executes nothing, so it needs no opted-in Project. What it can
        change is whether the *next* instruction is allowed to run at all, so the
        reply always states the remote-control status of the Project it moved to
        rather than leaving the operator to discover it on their next refusal.

        The change goes through Merge-DpSettings, which is the boundary that
        validates a selection and derives workspaceFolder from it.
    .PARAMETER ProjectId
        The id of the Project to select.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Applies an already-authorised remote selection on the accept thread; ShouldProcess is not meaningful there.')]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$ProjectId
    )

    $state = $script:DeskPilot

    $project = @(Get-DpIntercomProjectList) | Where-Object { $_.id -eq $ProjectId } | Select-Object -First 1
    if (-not $project) {
        $null = Send-DpIntercomMessage -Title 'I could not find that one.' -Line @(
            'It may have been removed. Send /projects for the current list.'
        ) -Kind 'notice'
        return
    }

    $previousProjectId = $state.Settings.selectedProjectId
    try {
        $state.Settings = Merge-DpSettings -Current $state.Settings -Patch @{ selectedProjectId = $ProjectId }
    }
    catch {
        $null = Send-DpIntercomMessage -Title 'I could not switch to that project.' -Line @("$_") -Kind 'notice'
        return
    }
    if ($state.TurnRunning -and $previousProjectId -cne $state.Settings.selectedProjectId) {
        $engine = Get-DpPropertyValue -InputObject $state -Name 'Engine'
        $approvalBridge = Get-DpPropertyValue -InputObject $engine -Name 'ApprovalBridge'
        if ($approvalBridge) { $approvalBridge.Cancel() }
        $state.PendingApproval = $null
    }
    if ($state.DataDir) { Save-DpSettings -Settings $state.Settings -Directory $state.DataDir }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("Project: $($project.name)")
    $lines.Add($project.path)
    # The switch itself runs nothing, so the reply is where the operator learns
    # whether the next instruction will - stated for the chat that asked, since a
    # group needs the second flag and would otherwise read a yes meant for the
    # operator's own phone.
    $fromGroup = (Test-DpIntercomChat -ChatId ([string](Get-DpPropertyValue -InputObject $state.Intercom -Name @('ReplyChatId') -Default ''))).group
    if (-not $project.remote) {
        $lines.Add("This project does not have 'allow phone control' ticked, so I cannot run anything in it from here.")
        $lines.Add('Tick it at the machine, in DeskPilot under Settings > Projects.')
    }
    elseif ($fromGroup -and -not $project.group) {
        $lines.Add('This project is not shared with group chats, so I cannot run anything in it from here.')
        $lines.Add("Only the operator's own chat can, until they tick 'also from a group chat' next to it under Settings > Projects.")
    }
    else {
        $lines.Add('Send an instruction whenever you are ready.')
    }
    $null = Send-DpIntercomMessage -Title 'Switched project.' -Line @($lines.ToArray()) -Kind 'project'
}
