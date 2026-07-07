function Get-DpMemoryPayload {
    <#
    .SYNOPSIS
        Builds the GET /api/memory response from the running state.
    .DESCRIPTION
        Returns the User Profile (the manual preferences Setting) and the Agent
        Memory store, each with its character count and cap, plus whether
        autonomous learning is enabled. Reads $script:DeskPilot, mirroring
        Get-DpUsagePayload.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $limits = Get-DpMemoryLimits
    $settings = $script:DeskPilot.Settings
    $userProfileText = if ($settings.ContainsKey('preferences') -and $settings.preferences) { [string]$settings.preferences } else { '' }
    $agentMemoryText = if ($script:DeskPilot.Memory) { [string]$script:DeskPilot.Memory.text } else { '' }
    $updated = if ($script:DeskPilot.Memory) { $script:DeskPilot.Memory.updatedUtc } else { $null }

    @{
        userProfile = @{ text = $userProfileText; chars = $userProfileText.Length; cap = $limits.userProfile }
        agentMemory = @{ text = $agentMemoryText; chars = $agentMemoryText.Length; cap = $limits.agentMemory; updatedUtc = $updated }
        learning    = [bool]$settings.memoryLearning
    }
}
