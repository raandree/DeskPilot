function Get-DpIntercomModelList {
    <#
    .SYNOPSIS
        Lists the Models Intercom can switch between.
    .DESCRIPTION
        Returns the Models this account is offered, each with the number the
        operator types to select it and a flag for the one the next Turn would run
        on.

        The list is read from the capability cache the /api/models route fills. A
        DeskPilot driven only from the phone may never have had a browser call that
        route, so an empty cache is refilled from the Engine here - but only while
        no Turn is running. The Engine Runspace is single-threaded, so asking it a
        question mid-Turn would park the accept thread, which is the same sentence
        as "the whole window freezes". The cache itself is left alone: it carries
        each Model's advertised reasoning efforts, and a half-shaped entry written
        here would reach Invoke-DpTurn.

        The numbering is a snapshot the caller remembers (Intercom.ModelIndex), the
        same way /chats and /agents do: the advertised list belongs to the account
        rather than to DeskPilot, and can change between listing and selecting.
    .PARAMETER MaxItems
        How many Models to offer. A phone list nobody scrolls is worse than a short
        one.
    .OUTPUTS
        System.Collections.Hashtable[]
    #>
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param(
        [ValidateRange(1, 60)]
        [int]$MaxItems = 25
    )

    $state = $script:DeskPilot

    $ids = @(@(Get-DpPropertyValue -InputObject $state -Name @('Models') -Default @()) |
            ForEach-Object { [string](Get-DpPropertyValue -InputObject $_ -Name @('id', 'Id', 'Name') -Default '') } |
            Where-Object { $_ })

    if ($ids.Count -eq 0 -and -not $state.TurnRunning) {
        try {
            $ids = @(Invoke-DpEngineCommand -Command 'Get-ShpModel' |
                    ForEach-Object { [string](Get-DpPropertyValue -InputObject $_ -Name @('Id', 'id', 'Name') -Default '') } |
                    Where-Object { $_ })
        }
        catch {
            Write-Verbose "Could not list the Engine's models for Intercom: $_"
            return @()
        }
    }

    $current = Get-DpIntercomModelId
    $number = 0
    foreach ($id in @($ids | Select-Object -First $MaxItems)) {
        $number++
        @{
            number  = $number
            id      = $id
            current = ($id -eq $current)
        }
    }
}
