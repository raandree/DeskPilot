function Initialize-DpQuestionnaireTool {
    <#
    .SYNOPSIS
        Registers DeskPilot's bundled Questionnaire Tool in the Engine Runspace.
    .DESCRIPTION
        Defines a trusted Runspace-local PowerShell command that waits on the
        existing UserPromptBridge, then registers it with ShellPilot as
        ask_questions. The Tool's description supplies the nested JSON contract
        that ShellPilot's metadata-derived string parameter cannot express.
    .PARAMETER Runspace
        The long-lived Engine Runspace with ShellPilot already imported.
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Runspaces.Runspace]$Runspace
    )

    $shell = [powershell]::Create()
    $shell.Runspace = $Runspace
    try {
        $null = $shell.AddScript(@'
function global:Invoke-DpQuestionnaireTool {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Questionnaire
    )

    $bridge = $global:DeskPilotUserPromptBridge
    if ($null -eq $bridge -or -not $bridge.Enabled) {
        throw 'The DeskPilot Questionnaire bridge is not active.'
    }
    $bridge.CaptureQuestion($Questionnaire)
    $bridge.RequestAnswer()
}

$description = @"
Ask the user one wizard-style Questionnaire. Use ONE call to bundle all related
questions that are currently known; do not ask them one at a time. Questionnaire
must be a compact JSON string shaped as
{"title":"Optional title","questions":[{"header":"Topic","question":"Complete question","options":[{"label":"Choice","description":"Optional detail"}],"multiSelect":false,"allowFreeformInput":true}]}.
Use 1-10 questions. Use options for useful known choices, multiSelect only when
several choices are valid, and allowFreeformInput only when a custom answer is
valid. A text-only question has options [] and allowFreeformInput true. The Tool
waits for the user and returns JSON with answers, selectedOptions, and freeText.
"@

$registerParams = @{
    Command     = 'Invoke-DpQuestionnaireTool'
    ToolName    = 'ask_questions'
    Description = $description
    Confirm     = $false
}
Register-ShpTool @registerParams
'@)
        $shell.Invoke() | Out-Null
        if ($shell.HadErrors) {
            $firstError = $shell.Streams.Error | Select-Object -First 1
            throw $(if ($firstError) { $firstError.ToString() } else { 'Could not register ask_questions.' })
        }
    }
    finally {
        $shell.Dispose()
    }

    $true
}
