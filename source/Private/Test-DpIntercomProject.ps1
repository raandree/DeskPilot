function Test-DpIntercomProject {
    <#
    .SYNOPSIS
        Reports whether the selected Project may be controlled remotely.
    .DESCRIPTION
        Intercom's authority boundary. A remote command may only act when a
        Project is selected and that Project carries intercom = true. Inside such
        a Project a remote Turn has exactly the same Permissions as a local one -
        the flag is the boundary, not a second Permission set.

        A command from an allow-listed group must clear a second flag,
        intercomGroup, on the same Project. Without it the boundary could not
        express 'the operator may drive me remotely, but the group may not': the
        first flag was ticked when the operator was the only possible caller, so
        allow-listing a group would retroactively hand every already-opted-in
        Project - git push included - to a membership Telegram controls.

        Returns a decision plus a sentence a non-expert can act on, so the refusal
        that reaches the phone explains itself.
    .PARAMETER Settings
        The current Settings hashtable.
    .PARAMETER OriginChatId
        The chat the command came from. Empty means the operator's own chat, which
        is also what a Turn started at the machine carries.
    .OUTPUTS
        System.Collections.Hashtable with allowed, reason and project.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Settings,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$OriginChatId
    )

    $selectedId = [string]$Settings.selectedProjectId
    if ([string]::IsNullOrWhiteSpace($selectedId)) {
        return @{
            allowed = $false
            reason  = 'No project is open in DeskPilot, so there is nothing to work on.'
            project = $null
        }
    }

    $project = @($Settings.projects) | Where-Object { $_ -and [string]$_.id -eq $selectedId } | Select-Object -First 1
    if (-not $project) {
        return @{
            allowed = $false
            reason  = 'The selected project could not be found.'
            project = $null
        }
    }

    # A Project is a hashtable in Settings and a PSCustomObject when it has just
    # been parsed from disk, and either may predate a flag entirely.
    $readFlag = {
        param($Item, [string]$Name)
        if ($Item -is [System.Collections.IDictionary]) {
            if ($Item.Contains($Name)) { return [bool]$Item[$Name] }
            return $false
        }
        $property = $Item.PSObject.Properties[$Name]
        if ($property) { return [bool]$property.Value }
        $false
    }

    if (-not (& $readFlag $project 'intercom')) {
        return @{
            allowed = $false
            reason  = "The project '$($project.name)' does not have 'allow phone control' ticked, so I cannot work in it from here. Tick it in DeskPilot under Settings > Projects."
            project = $project
        }
    }

    # The group is a wider caller than the phone the first flag was ticked for, so
    # it needs its own grant on this Project rather than inheriting that one.
    $origin = Test-DpIntercomChat -ChatId $OriginChatId -Settings $Settings
    if ($origin.group -and -not (& $readFlag $project 'intercomGroup')) {
        return @{
            allowed = $false
            reason  = "The project '$($project.name)' is not shared with group chats, so I cannot work in it from a group. Only the operator's own chat can. They can share it by ticking 'also from a group chat' in DeskPilot under Settings > Projects."
            project = $project
        }
    }

    @{ allowed = $true; reason = ''; project = $project }
}
