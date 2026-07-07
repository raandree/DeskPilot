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
        # Memory & context. When autoCompaction is on, a Conversation whose last
        # Turn filled its Model context window to at least compactionThreshold is
        # summarised automatically after the Turn (the same summarise-and-keep-tail
        # the manual Compact action performs), so a long Conversation keeps working
        # instead of overflowing the window. compactionKeepRecent is how many recent
        # history entries stay verbatim (the rest are summarised). Defaults: on, at
        # 80% full, keeping the last 4 entries.
        autoCompaction       = $true
        compactionThreshold  = 0.8
        compactionKeepRecent = 4
        # Persistent memory. When memoryLearning is on, after a Turn DeskPilot runs
        # a throttled, best-effort pure-reasoning pass that folds durable facts from
        # the conversation into the agent's Memory (see Get-DpMemoryLimits). The
        # User Profile is the manual preferences block above; the Agent Memory store
        # lives in agent-memory.json, not in Settings.
        memoryLearning       = $true
    }
}
