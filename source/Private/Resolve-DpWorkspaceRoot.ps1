function Resolve-DpWorkspaceRoot {
    <#
    .SYNOPSIS
        Resolves the Workspace Folder a Tool is confined to, link target included.
    .DESCRIPTION
        The one place a Tool turns the configured Workspace Folder into the prefix
        every later confinement test compares against. It resolves the folder
        through its own link target first: a Workspace Folder that is itself a
        junction would otherwise make every resolved candidate fail to match an
        unresolved prefix, and a confinement test that fails open is worse than
        none.

        No Project selected, a path that is not a folder, and a folder that cannot
        be read all yield the same answer, because the model can act on all three
        the same way: ask the user to select a Project.
    .PARAMETER Root
        The configured Workspace Folder.
    .OUTPUTS
        System.Collections.Hashtable with ok, root, error and message.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Root
    )

    $failure = @{
        ok      = $false
        root    = ''
        error   = 'no-workspace'
        message = 'No Project is selected, so there is no folder to work in. Ask the user to select a Project (a Workspace Folder) in DeskPilot, then try again. Do not use any other folder.'
    }

    if ([string]::IsNullOrWhiteSpace($Root)) { return $failure }

    try {
        $item = Get-Item -LiteralPath $Root -Force -ErrorAction Stop
        if ($item -isnot [System.IO.DirectoryInfo]) { return $failure }
        $target = $item.ResolveLinkTarget($true)
        $resolved = [System.IO.Path]::GetFullPath($(if ($target) { $target.FullName } else { $item.FullName }))
    }
    catch {
        $rootError = $_
        Write-Verbose "Could not resolve the workspace folder '$Root': $rootError"
        return $failure
    }

    @{ ok = $true; root = $resolved; error = ''; message = '' }
}
