function New-DpSupportBundleRecord {
    <#
    .SYNOPSIS
        Constructs the structured support-bundle record from field allow-lists.
    .DESCRIPTION
        Copies only version, path-purpose, enabled-state, check, and redacted log
        fields. Live state objects are never serialized. Absolute paths, Messages,
        Attachments, Tool arguments, environment values, credentials, and unknown
        fields have no route into the returned object.
    .OUTPUTS
        System.Collections.Specialized.OrderedDictionary
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs and returns allow-listed in-memory data without writing it.')]
    param()

    $state = $script:DeskPilot
    $snapshot = New-DpDiagnosticSnapshot
    $settings = $state.Settings
    $diagnostics = $state.Diagnostics

    $permissions = Get-DpPropertyValue -InputObject $settings -Name @('permissions') -Default @{}
    $permissionRecord = [ordered]@{}
    foreach ($name in 'browsing', 'file', 'terminal', 'askUser', 'userTools', 'mcp') {
        $permissionRecord[$name] = [bool](Get-DpPropertyValue -InputObject $permissions -Name @($name) -Default $false)
    }

    $mcpRows = @()
    foreach ($row in @(Get-DpPropertyValue -InputObject $settings -Name @('mcpServers') -Default @())) {
        $mcpRows += [ordered]@{
            name                   = (Protect-DpDiagnosticText -Text ([string](Get-DpPropertyValue -InputObject $row -Name @('name') -Default '')) -MaxLength 80)
            source                 = (Protect-DpDiagnosticText -Text ([string](Get-DpPropertyValue -InputObject $row -Name @('source') -Default '')) -MaxLength 20)
            enabled                = [bool](Get-DpPropertyValue -InputObject $row -Name @('enabled') -Default $true)
            environmentKeyCount    = @(Get-DpPropertyValue -InputObject $row -Name @('envKeys') -Default @()).Count
            toolRestrictionCount   = @(Get-DpPropertyValue -InputObject $row -Name @('tools') -Default @()).Count
        }
    }

    $intercomSettings = Get-DpPropertyValue -InputObject $settings -Name @('intercom') -Default @{}
    $configuration = [ordered]@{
        settingCount    = [int]$snapshot.configuration.settingCount
        permissionCount = [int]$snapshot.configuration.permissionCount
        permissions     = $permissionRecord
        features        = [ordered]@{
            taskTracking             = [bool](Get-DpPropertyValue -InputObject $settings -Name @('taskTracking') -Default $false)
            turnTranscript            = [bool](Get-DpPropertyValue -InputObject $settings -Name @('turnTranscript') -Default $false)
            memoryLearning            = [bool](Get-DpPropertyValue -InputObject $settings -Name @('memoryLearning') -Default $false)
            autoCompaction            = [bool](Get-DpPropertyValue -InputObject $settings -Name @('autoCompaction') -Default $false)
            updateIncludePrereleases = [bool](Get-DpPropertyValue -InputObject $settings -Name @('updateIncludePrereleases') -Default $false)
        }
        mcpServers      = $mcpRows
        intercom       = [ordered]@{
            enabled         = [bool](Get-DpPropertyValue -InputObject $intercomSettings -Name @('enabled') -Default $false)
            tokenConfigured = [bool](Get-DpPropertyValue -InputObject $state.Intercom -Name @('TokenConfigured') -Default $false)
            chatConfigured  = -not [string]::IsNullOrWhiteSpace([string](Get-DpPropertyValue -InputObject $intercomSettings -Name @('chatId') -Default ''))
            groupEnabled    = [bool](Get-DpPropertyValue -InputObject $intercomSettings -Name @('allowGroupChat') -Default $false)
            groupCount      = @(Get-DpPropertyValue -InputObject $intercomSettings -Name @('groupChatIds') -Default @()).Count
        }
    }

    $pathMarkers = @(
        @{ path = [string]$snapshot.paths.module; purpose = 'Engine module' }
        @{ path = [string]$snapshot.project.path; purpose = 'Project' }
        @{ path = [string]$snapshot.paths.data; purpose = 'DeskPilot data' }
    )
    $checks = @()
    $lastVersions = Get-DpPropertyValue -InputObject $diagnostics.LastCheck -Name @('versions') -Default @{}
    $lastChecks = @(Get-DpPropertyValue -InputObject $diagnostics.LastCheck -Name @('checks') -Default @())
    foreach ($check in $lastChecks) {
        $stateName = [string](Get-DpPropertyValue -InputObject $check -Name @('state') -Default 'degraded')
        if ($stateName -notin @('healthy', 'degraded', 'unavailable', 'not configured')) { $stateName = 'degraded' }
        $detail = @{}
        foreach ($key in 'version', 'configuredCount', 'enabledCount', 'healthyCount', 'degradedCount') {
            $value = Get-DpPropertyValue -InputObject $check -Name @($key) -Default $null
            if ($null -ne $value) { $detail[$key] = $value }
        }
        $checkExplanation = Protect-DpSupportBundleText `
            -Text ([string](Get-DpPropertyValue -InputObject $check -Name @('explanation') -Default 'No result was available.')) `
            -PathMarker $pathMarkers
        $checkAction = Protect-DpSupportBundleText `
            -Text ([string](Get-DpPropertyValue -InputObject $check -Name @('action') -Default 'Run the self-check again.')) `
            -PathMarker $pathMarkers
        $checks += New-DpDiagnosticCheck `
            -Id ([string](Get-DpPropertyValue -InputObject $check -Name @('id') -Default 'unknown')) `
            -Label ([string](Get-DpPropertyValue -InputObject $check -Name @('label') -Default 'Unknown')) `
            -State $stateName `
            -Explanation $checkExplanation -Action $checkAction `
            -Detail $detail
    }

    $logEntries = @()
    foreach ($entry in @(Get-DpDiagnosticLog -Log $diagnostics.Log)) {
        $summary = Protect-DpSupportBundleText `
            -Text ([string](Get-DpPropertyValue -InputObject $entry -Name @('summary') -Default '')) `
            -PathMarker $pathMarkers
        $logEntries += [ordered]@{
            sequence  = [long](Get-DpPropertyValue -InputObject $entry -Name @('sequence') -Default 0)
            timestamp = [string](Get-DpPropertyValue -InputObject $entry -Name @('timestamp') -Default '')
            severity  = [string](Get-DpPropertyValue -InputObject $entry -Name @('severity') -Default '')
            component = [string](Get-DpPropertyValue -InputObject $entry -Name @('component') -Default '')
            eventId   = [string](Get-DpPropertyValue -InputObject $entry -Name @('eventId') -Default '')
            summary   = $summary
        }
    }

    [ordered]@{
        schemaVersion = 1
        createdUtc    = [datetime]::UtcNow.ToString('o')
        versions      = [ordered]@{
            deskPilot       = [string]$snapshot.versions.deskPilot
            powerShell      = [string]$snapshot.versions.powerShell
            engine          = [string]$snapshot.versions.engine
            git             = [string](Get-DpPropertyValue -InputObject $lastVersions -Name @('git') -Default '')
            operatingSystem = [string]$snapshot.versions.operatingSystem
        }
        paths         = [ordered]@{
            data = [ordered]@{
                purpose = 'DeskPilot data'
                leaf    = $(if ($snapshot.paths.data) { Split-Path -Path $snapshot.paths.data -Leaf } else { '' })
            }
            module = [ordered]@{
                purpose = 'Engine module'
                leaf    = $(if ($snapshot.paths.module) { Split-Path -Path $snapshot.paths.module -Leaf } else { '' })
            }
        }
        project       = [ordered]@{
            configured = [bool]$snapshot.project.configured
            name       = [string]$snapshot.project.name
            folderLeaf = $(if ($snapshot.project.path) { Split-Path -Path $snapshot.project.path -Leaf } else { '' })
        }
        configuration = $configuration
        checks        = $checks
        logs          = $logEntries
    }
}