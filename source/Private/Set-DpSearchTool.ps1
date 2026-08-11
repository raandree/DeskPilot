function Set-DpSearchTool {
    <#
    .SYNOPSIS
        Enables or removes the search Tools in the Engine Runspace.
    .DESCRIPTION
        Re-registers search_files and search_text when File Access is on, and
        removes them when it is off. Registered User Tools are a separate Engine
        category from the built-in file Tools, so -DisableFileAccess does not
        touch them: without this the search Tools would keep reading the
        workspace after the user had switched file access off, which is the
        Permission meaning something in the UI and nothing in fact.

        Re-registration also carries the current Workspace Folder, so switching
        Project moves the search with it rather than leaving the previous
        Project's root behind.
    .PARAMETER Runspace
        The idle, long-lived Engine Runspace.
    .PARAMETER Enabled
        Whether the search Tools must be available for the next Turn.
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
        return Initialize-DpSearchTool -Runspace $Runspace -Root $Root
    }

    $shell = [powershell]::Create()
    $shell.Runspace = $Runspace
    try {
        # Unregister-ShpTool only warns about a name it does not hold, so removal
        # is safe to run on a runspace that never had the tools.
        $null = $shell.AddScript(@'
Set-Variable -Name DeskPilotSearchRoot -Scope Global -Value ''
Unregister-ShpTool -Name 'search_files' -Confirm:$false -WarningAction SilentlyContinue
Unregister-ShpTool -Name 'search_text' -Confirm:$false -WarningAction SilentlyContinue
'@)
        $shell.Invoke() | Out-Null
        if ($shell.HadErrors) {
            $firstError = $shell.Streams.Error | Select-Object -First 1
            throw $(if ($firstError) { $firstError.ToString() } else { 'Could not remove the search tools.' })
        }
    }
    finally {
        $shell.Dispose()
    }

    $false
}
