function Set-DpWorkspaceTool {
    <#
    .SYNOPSIS
        Enables or removes DeskPilot's workspace Tools in the Engine Runspace.
    .DESCRIPTION
        Re-registers search_files, search_text and replace_in_file when File
        Access is on, and removes them when it is off. Registered User Tools are a
        separate Engine category from the built-in file Tools, so
        -DisableFileAccess does not touch them: without this the search and edit
        Tools would keep reading and writing the workspace after the user had
        switched file access off, which is the Permission meaning something in the
        UI and nothing in fact.

        Re-registration also carries the current Workspace Folder and resets the
        edited-file ledger, so switching Project moves the Tools with it and one
        Turn's edits are never attributed to the next.
    .PARAMETER Runspace
        The idle, long-lived Engine Runspace.
    .PARAMETER Enabled
        Whether the workspace Tools must be available for the next Turn.
    .PARAMETER Root
        The Workspace Folder to confine the Tools to when enabling.
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Runspaces.Runspace]$Runspace,

        [Parameter(Mandatory)]
        [bool]$Enabled,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Root
    )

    if ($Enabled) {
        return Initialize-DpWorkspaceTool -Runspace $Runspace -Root $Root
    }

    $shell = [powershell]::Create()
    $shell.Runspace = $Runspace
    try {
        # Unregister-ShpTool only warns about a name it does not hold, so removal
        # is safe to run on a runspace that never had the tools.
        $null = $shell.AddScript(@'
Set-Variable -Name DeskPilotWorkspaceRoot -Scope Global -Value ''
Set-Variable -Name DeskPilotFilesEdited -Scope Global -Value ([System.Collections.Generic.List[string]]::new())
foreach ($toolName in @('search_files', 'search_text', 'replace_in_file')) {
    Unregister-ShpTool -Name $toolName -Confirm:$false -WarningAction SilentlyContinue
}
'@)
        $shell.Invoke() | Out-Null
        if ($shell.HadErrors) {
            $firstError = $shell.Streams.Error | Select-Object -First 1
            throw $(if ($firstError) { $firstError.ToString() } else { 'Could not remove the workspace tools.' })
        }
    }
    finally {
        $shell.Dispose()
    }

    $false
}
