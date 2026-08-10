function Get-DpIntercomProjectList {
    <#
    .SYNOPSIS
        Lists the Projects Intercom can switch between.
    .DESCRIPTION
        Returns the registered Projects in the order Settings holds them, each with
        the number the operator types to select it, the one currently open, and
        whether that Project has opted into remote control.

        The remote flag is reported rather than used as a filter: a Project that has
        not opted in can still be switched to - switching executes nothing - and
        listing only the opted-in ones would hide the very Project the operator
        wants to be told about.
    .PARAMETER MaxItems
        How many Projects to offer.
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
    $selectedId = [string]$state.Settings.selectedProjectId

    $number = 0
    foreach ($project in @(@($state.Settings.projects) | Where-Object { $_ } | Select-Object -First $MaxItems)) {
        $number++
        $name = [string](Get-DpPropertyValue -InputObject $project -Name @('name') -Default '')
        if ($name.Length -gt 60) { $name = $name.Substring(0, 60) + '...' }
        @{
            number  = $number
            id      = [string](Get-DpPropertyValue -InputObject $project -Name @('id') -Default '')
            name    = $name
            path    = [string](Get-DpPropertyValue -InputObject $project -Name @('path') -Default '')
            current = ([string](Get-DpPropertyValue -InputObject $project -Name @('id') -Default '') -eq $selectedId)
            remote  = [bool](Get-DpPropertyValue -InputObject $project -Name @('intercom') -Default $false)
        }
    }
}
