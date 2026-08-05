function Set-DpQuestionnaireTool {
    <#
    .SYNOPSIS
        Enables or removes the Questionnaire Tool in the Engine Runspace.
    .DESCRIPTION
        Re-registers ask_questions when Ask-User permission is on and removes it
        when that Permission is off. This keeps the registered User Tool aligned
        with the Ask-User boundary without changing the user's general User Tool
        permission.
    .PARAMETER Runspace
        The idle, long-lived Engine Runspace.
    .PARAMETER Enabled
        Whether ask_questions must be available for the next Turn.
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Runspaces.Runspace]$Runspace,

        [Parameter(Mandatory)]
        [bool]$Enabled
    )

    if ($Enabled) {
        return Initialize-DpQuestionnaireTool -Runspace $Runspace
    }

    $shell = [powershell]::Create()
    $shell.Runspace = $Runspace
    try {
        $null = $shell.AddCommand('Unregister-ShpTool')
        $null = $shell.AddParameter('Name', 'ask_questions')
        $null = $shell.AddParameter('Confirm', $false)
        $shell.Invoke() | Out-Null
        if ($shell.HadErrors) {
            $firstError = $shell.Streams.Error | Select-Object -First 1
            throw $(if ($firstError) { $firstError.ToString() } else { 'Could not remove ask_questions.' })
        }
    }
    finally {
        $shell.Dispose()
    }

    $false
}
