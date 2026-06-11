function Get-DpDefaultSettings {
    <#
    .SYNOPSIS
        Returns the default DeskPilot Settings object.
    .DESCRIPTION
        Produces a fresh hashtable of default Settings used by the Host Server.
        Terminal Permission defaults off because it is the highest-risk Tool for
        a non-technical user.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $copilot = Get-DpCopilotDefaults

    @{
        model             = $null
        permissions       = @{
            browsing  = $true
            file      = $true
            terminal  = $false
            askUser   = $true
            userTools = $true
        }
        projects          = @()
        selectedProjectId = $null
        workspaceFolder   = $null
        agentsRoot        = $copilot.agentsRoot
        selectedAgent     = $null
        skillRoots        = @($copilot.skillRoots)
        instructionRoots  = @($copilot.instructionRoots)
        promptRoots       = @($copilot.promptRoots)
        reasoningEffort   = $null
        showThinking      = $false
        taskTracking      = $true
        preferences       = $null
        referenceFiles    = @()
        costBudgetUSD     = 0.0
        maxToolIterations = 25
    }
}
