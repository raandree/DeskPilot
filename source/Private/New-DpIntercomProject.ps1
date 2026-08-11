function New-DpIntercomProject {
    <#
    .SYNOPSIS
        Registers a folder as a Project from the phone, creating it if needed.
    .DESCRIPTION
        The remote half of "add a project". It validates the folder the operator
        sent, creates it when only the last segment is missing, registers it through
        Merge-DpSettings (which owns the duplicate-name and duplicate-path rules)
        and selects it.

        Two boundaries make this safe to expose to a messenger:

        It writes to disk, so unlike listing and switching it requires the currently
        selected Project to have opted into remote control. That is the same split
        the rest of Intercom uses - navigation is free, work is not - and it means a
        phone that cannot run anything cannot create folders either.

        The new Project is **never** remote-enabled. If a remote message could opt a
        folder into remote control, the Project flag would be decorative: anyone
        holding the phone could point DeskPilot at any folder and run there. The
        flag is set at the machine, and the reply says so.
    .PARAMETER Path
        The absolute folder path the operator sent.
    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Applies an already-authorised remote request on the accept thread; ShouldProcess is not meaningful there.')]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Path
    )

    $state = $script:DeskPilot

    $raw = ([string]$Path).Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($raw)) {
        $null = Send-DpIntercomMessage -Title 'Which folder?' -Line @(
            'Send the full path, for example /project new C:\Git\Notes.'
        ) -Kind 'notice'
        return
    }
    if ($raw.Length -gt 260) {
        $null = Send-DpIntercomMessage -Title 'That path is too long.' -Kind 'notice'
        return
    }
    if (-not [System.IO.Path]::IsPathRooted($raw)) {
        $null = Send-DpIntercomMessage -Title 'That is not a full path.' -Line @(
            'Send the whole path, for example /project new C:\Git\Notes.'
        ) -Kind 'notice'
        return
    }

    $separators = @([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    try {
        $full = [System.IO.Path]::GetFullPath($raw)
    }
    catch {
        $null = Send-DpIntercomMessage -Title 'I could not read that path.' -Line @("$_") -Kind 'notice'
        return
    }
    # An empty leaf means a drive root or '/': a whole volume is not a project, and
    # the parent-must-exist rule below has nothing to check against.
    $leaf = [System.IO.Path]::GetFileName($full.TrimEnd($separators))
    if ([string]::IsNullOrWhiteSpace($leaf)) {
        $null = Send-DpIntercomMessage -Title 'A whole drive cannot be a project.' -Line @(
            'Send a folder inside it, for example /project new C:\Git\Notes.'
        ) -Kind 'notice'
        return
    }
    $full = $full.TrimEnd($separators)

    # Already registered: switching to it is what the operator meant, and is
    # friendlier than refusing over a duplicate they cannot see from a phone.
    $pathKey = ($full -replace '[\\/]+$', '').ToLowerInvariant()
    $existing = @(Get-DpIntercomProjectList) | Where-Object { ($_.path -replace '[\\/]+$', '').ToLowerInvariant() -eq $pathKey } | Select-Object -First 1
    if ($existing) {
        Switch-DpIntercomProject -ProjectId $existing.id
        return
    }

    # Creating a folder is a change on disk, so it needs the same authority running
    # an instruction does - navigation is free, work is not.
    $decision = Test-DpIntercomProject -Settings $state.Settings
    if (-not $decision.allowed) {
        $null = Send-DpIntercomMessage -Title 'I cannot add a project from here.' -Line @(
            $decision.reason,
            'Add it at the machine, in DeskPilot under Settings > Projects.'
        ) -Kind 'refused'
        return
    }

    $created = $false
    if (Test-Path -LiteralPath $full -PathType Leaf) {
        $null = Send-DpIntercomMessage -Title 'That is a file, not a folder.' -Kind 'notice'
        return
    }
    if (-not (Test-Path -LiteralPath $full -PathType Container)) {
        $parent = [System.IO.Path]::GetDirectoryName($full)
        if ([string]::IsNullOrWhiteSpace($parent) -or -not (Test-Path -LiteralPath $parent -PathType Container)) {
            $null = Send-DpIntercomMessage -Title 'That folder does not exist.' -Line @(
                "Neither does the folder above it: $parent",
                'I only create the last folder in a path, so send one whose parent already exists.'
            ) -Kind 'notice'
            return
        }
        try {
            $full = New-DpDirectory -Parent $parent -Name $leaf
            $created = $true
        }
        catch {
            $null = Send-DpIntercomMessage -Title 'I could not create that folder.' -Line @("$_") -Kind 'notice'
            return
        }
    }

    $project = @{ id = (New-DpId -Prefix 'p'); name = $leaf; path = $full }
    $keep = @(@($state.Settings.projects) | Where-Object { $_ })
    try {
        $state.Settings = Merge-DpSettings -Current $state.Settings -Patch @{
            projects          = @($keep + $project)
            selectedProjectId = $project.id
        }
    }
    catch {
        $null = Send-DpIntercomMessage -Title 'I could not add that project.' -Line @("$_") -Kind 'notice'
        return
    }
    if ($state.DataDir) { Save-DpSettings -Settings $state.Settings -Directory $state.DataDir }

    $null = Send-DpIntercomMessage -Title $(if ($created) { 'Folder created and added as a project.' } else { 'Project added.' }) -Line @(
        "Project: $($project.name)",
        $project.path,
        "It does not have 'allow phone control' ticked, so I cannot run anything in it from here yet.",
        'Tick it at the machine, in DeskPilot under Settings > Projects.'
    ) -Kind 'project'
}
