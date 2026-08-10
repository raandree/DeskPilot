function Get-DpIntercomAgentList {
    <#
    .SYNOPSIS
        Lists the Agents Intercom can switch between.
    .DESCRIPTION
        Returns the Agents discovered under the effective Agents folder, each with
        the number the operator types to select it and a flag for the one already
        selected.

        The numbering is a snapshot the caller remembers (Intercom.AgentIndex), the
        same way /chats does: the folder can gain or lose a file between listing and
        selecting, and the number the operator saw must be the Agent they get.
    .PARAMETER MaxItems
        How many Agents to offer. A phone list nobody scrolls is worse than a short
        one, and the count left out is reported by the caller.
    .OUTPUTS
        System.Collections.Hashtable[]
    #>
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param(
        [ValidateRange(1, 50)]
        [int]$MaxItems = 20
    )

    $state = $script:DeskPilot
    $root = Resolve-DpAgentsRoot -Settings $state.Settings
    if (-not $root) { return @() }

    $selected = [string]$state.Settings.selectedAgent
    $number = 0
    foreach ($agent in @(Get-DpAgentList -Root $root | Select-Object -First $MaxItems)) {
        $number++
        $name = [string]$agent.name
        if ($name.Length -gt 60) { $name = $name.Substring(0, 60) + '...' }
        @{
            number  = $number
            id      = [string]$agent.id
            name    = $name
            current = ([string]$agent.id -eq $selected)
        }
    }
}
