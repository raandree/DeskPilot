function Get-DpMemoryPayload {
    <#
    .SYNOPSIS
        Builds the GET /api/memory response from the running state.
    .DESCRIPTION
        Returns the User Profile (the manual preferences Setting) and the Agent
        Memory store, each with its character count and cap, plus whether
        autonomous learning is enabled. Reads $script:DeskPilot, mirroring
        Get-DpUsagePayload.

        The Agent Memory is answered twice, on purpose. text is the version-1
        view: the GLOBAL notes as plain text, which is exactly what an existing
        client shows in its textarea and writes back, so nothing it can see is
        lost and nothing it cannot see is put at risk by its edit. notes is the
        structured view: every note with the origin, scope, Conversation,
        timestamps and verification DeskPilot actually recorded, so the UI can
        show where a fact came from and let the user forget it.

        Project names are resolved here rather than in the UI so the two cannot
        disagree about which Project a note belongs to; a note whose Project has
        since been removed keeps its id and reports no name.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $limits = Get-DpMemoryLimits
    $settings = $script:DeskPilot.Settings
    $userProfileText = if ($settings.ContainsKey('preferences') -and $settings.preferences) { [string]$settings.preferences } else { '' }

    $memory = Get-DpPropertyValue -InputObject $script:DeskPilot -Name @('Memory') -Default $null
    $agentMemoryText = [string](Get-DpPropertyValue -InputObject $memory -Name @('text') -Default '')
    $updated = Get-DpPropertyValue -InputObject $memory -Name @('updatedUtc') -Default $null
    $loadError = Get-DpPropertyValue -InputObject $memory -Name @('loadError') -Default $null
    $notes = @(Get-DpPropertyValue -InputObject $memory -Name @('notes') -Default @())

    $projectNames = @{}
    foreach ($project in @(Get-DpPropertyValue -InputObject $settings -Name @('projects') -Default @())) {
        $projectId = [string](Get-DpPropertyValue -InputObject $project -Name @('id') -Default '')
        if ($projectId) { $projectNames[$projectId] = [string](Get-DpPropertyValue -InputObject $project -Name @('name') -Default '') }
    }
    $selectedId = [string](Get-DpPropertyValue -InputObject $settings -Name @('selectedProjectId') -Default '')

    $noteViews = @($notes | ForEach-Object {
            @{
                id             = $_.id
                text           = $_.text
                source         = $_.source
                scope          = $_.scope
                projectId      = $_.projectId
                projectName    = $(if ($_.projectId -and $projectNames.ContainsKey($_.projectId)) { $projectNames[$_.projectId] } else { $null })
                conversationId = $_.conversationId
                createdUtc     = $_.createdUtc
                updatedUtc     = $_.updatedUtc
                verified       = [bool]$_.verified
            }
        })

    @{
        userProfile = @{ text = $userProfileText; chars = $userProfileText.Length; cap = $limits.userProfile }
        agentMemory = @{
            text       = $agentMemoryText
            chars      = $agentMemoryText.Length
            cap        = $limits.agentMemory
            updatedUtc = $updated
            notes      = $noteViews
            noteCount  = $noteViews.Count
            noteCap    = $limits.note
            maxNotes   = $limits.noteCount
            # Null unless the persisted store could not be read in full, in which
            # case the UI has to say so rather than present a silent empty memory.
            loadError  = $loadError
            project    = @{
                id   = $(if ($selectedId) { $selectedId } else { $null })
                name = $(if ($selectedId -and $projectNames.ContainsKey($selectedId)) { $projectNames[$selectedId] } else { $null })
            }
        }
        learning    = [bool]$settings.memoryLearning
    }
}
