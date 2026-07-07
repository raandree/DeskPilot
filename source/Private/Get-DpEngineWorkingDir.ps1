function Get-DpEngineWorkingDir {
    <#
    .SYNOPSIS
        Resolves the working directory the Engine Runspace runs a Turn in.
    .DESCRIPTION
        Returns the directory the Engine's File and Terminal Tools resolve
        relative paths against for the next Turn. When a Workspace Folder is
        active (a Project is selected) the Turn runs there. When no Project is
        selected - for example after the active Project has been closed, or
        before one has ever been chosen - the Turn falls back to a neutral
        "workspace" subfolder of the per-user data directory instead of
        inheriting whatever directory the long-lived Engine Runspace happened to
        be pointed at (the folder DeskPilot was launched from, or a previously
        selected Project whose location persisted). That determinism stops a
        no-Project Turn from silently reading files - for example a
        ".memory-bank" folder - that belong to an unrelated context. Only the
        path is resolved here; the caller creates the directory (as
        Set-DpEngineLocation does).
    .PARAMETER WorkspaceFolder
        The active Workspace Folder, or $null/empty when no Project is selected.
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$WorkspaceFolder
    )

    if (-not [string]::IsNullOrWhiteSpace($WorkspaceFolder)) {
        return $WorkspaceFolder
    }

    Join-Path (Get-DpDataDir) 'workspace'
}
