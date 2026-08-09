function Test-DpIntercomProject {
    <#
    .SYNOPSIS
        Reports whether the selected Project may be controlled remotely.
    .DESCRIPTION
        Intercom's authority boundary. A remote command may only act when a
        Project is selected and that Project carries intercom = true. Inside such
        a Project a remote Turn has exactly the same Permissions as a local one -
        the flag is the boundary, not a second Permission set.

        Returns a decision plus a sentence a non-expert can act on, so the refusal
        that reaches the phone explains itself.
    .PARAMETER Settings
        The current Settings hashtable.
    .OUTPUTS
        System.Collections.Hashtable with allowed, reason and project.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Settings
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

    $enabled = $false
    if ($project -is [System.Collections.IDictionary]) {
        if ($project.Contains('intercom')) { $enabled = [bool]$project['intercom'] }
    }
    elseif ($project.PSObject.Properties['intercom']) {
        $enabled = [bool]$project.PSObject.Properties['intercom'].Value
    }

    if (-not $enabled) {
        return @{
            allowed = $false
            reason  = "Remote control is switched off for the project '$($project.name)'. Turn it on in DeskPilot under Settings > Intercom."
            project = $project
        }
    }

    @{ allowed = $true; reason = ''; project = $project }
}
