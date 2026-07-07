function Get-DpUploadDir {
    <#
    .SYNOPSIS
        Resolves the directory an uploaded file is written to.
    .DESCRIPTION
        Returns the target directory for POST /api/uploads. When a Workspace
        Folder is active the upload lands there, so the agent reads it with its
        File Tool from its working directory. When no Workspace Folder is active
        - for example after the active Project has been closed - the upload
        falls back to an "uploads" subfolder of the per-user data directory, so
        attaching a file never requires a registered Project. Only the path is
        resolved here; the caller creates the directory.
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

    Join-Path (Get-DpDataDir) 'uploads'
}