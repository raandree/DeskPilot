function New-DpDiagnosticSnapshot {
    <#
    .SYNOPSIS
        Captures allow-listed Host Server facts for a self-check.
    .DESCRIPTION
        Builds a fresh record from approved scalar fields and counts. It never
        serializes live state, Settings values, Messages, Attachments, Tool
        arguments, tokens, cookies, authorization headers, or environment values.
    .OUTPUTS
        System.Collections.Specialized.OrderedDictionary
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Projects current state into a read-only in-memory snapshot.')]
    param()

    $state = $script:DeskPilot
    $settings = $state.Settings
    $engine = $state.Engine

    $projects = @(Get-DpPropertyValue -InputObject $settings -Name @('projects') -Default @())
    $selectedId = [string](Get-DpPropertyValue -InputObject $settings -Name @('selectedProjectId') -Default '')
    $workspaceFolder = [string](Get-DpPropertyValue -InputObject $settings -Name @('workspaceFolder') -Default '')
    $selectedProject = $projects | Where-Object {
        [string](Get-DpPropertyValue -InputObject $_ -Name @('id') -Default '') -eq $selectedId
    } | Select-Object -First 1
    $projectName = [string](Get-DpPropertyValue -InputObject $selectedProject -Name @('name') -Default '')
    if (-not $projectName -and $workspaceFolder) { $projectName = Split-Path -Path $workspaceFolder -Leaf }

    $permission = Get-DpPropertyValue -InputObject $settings -Name @('permissions') -Default @{}
    $permissionCount = if ($permission -is [System.Collections.IDictionary]) { $permission.Count } else { 0 }
    $settingCount = if ($settings -is [System.Collections.IDictionary]) { $settings.Count } else { 0 }
    $configurationValid = $settings -is [System.Collections.IDictionary] -and
        $permission -is [System.Collections.IDictionary] -and
        $permissionCount -ge 6

    $configuredRows = @(Get-DpPropertyValue -InputObject $settings -Name @('mcpServers') -Default @())
    $enabledRows = @($configuredRows | Where-Object {
            [bool](Get-DpPropertyValue -InputObject $_ -Name @('enabled') -Default $true)
        })
    $observation = Get-DpPropertyValue -InputObject $state.Mcp -Name @('LastObserved') -Default $null
    $observationAvailable = $null -ne $observation -and
        [bool](Get-DpPropertyValue -InputObject $observation -Name @('available') -Default $true)
    $observedRows = @(Get-DpPropertyValue -InputObject $observation -Name @('rows') -Default @())
    $healthyCount = 0
    $degradedCount = 0
    $mcpIssue = [string](Get-DpPropertyValue -InputObject $observation -Name @('issue') -Default '')
    foreach ($row in $enabledRows) {
        $rowId = [string](Get-DpPropertyValue -InputObject $row -Name @('id') -Default '')
        $observedRow = $observedRows | Where-Object {
            [string](Get-DpPropertyValue -InputObject $_ -Name @('id') -Default '') -eq $rowId
        } | Select-Object -First 1
        $servers = @(Get-DpPropertyValue -InputObject $observedRow -Name @('servers') -Default @())
        $rowOk = [bool](Get-DpPropertyValue -InputObject $observedRow -Name @('ok') -Default $false)
        $allRunning = $servers.Count -gt 0 -and -not @($servers | Where-Object {
                -not [bool](Get-DpPropertyValue -InputObject $_ -Name @('running') -Default $false) -or
                [string](Get-DpPropertyValue -InputObject $_ -Name @('state') -Default '') -eq 'Faulted'
            })
        if ($rowOk -and $allRunning) {
            $healthyCount++
        }
        else {
            $degradedCount++
            if (-not $mcpIssue) {
                $mcpIssue = [string](Get-DpPropertyValue -InputObject $observedRow -Name @('error') -Default '')
                if (-not $mcpIssue) {
                    $faulted = $servers | Where-Object {
                        -not [bool](Get-DpPropertyValue -InputObject $_ -Name @('running') -Default $false) -or
                        [string](Get-DpPropertyValue -InputObject $_ -Name @('state') -Default '') -eq 'Faulted'
                    } | Select-Object -First 1
                    $mcpIssue = [string](Get-DpPropertyValue -InputObject $faulted -Name @('faultReason') -Default '')
                }
            }
        }
    }

    $intercomSettings = Get-DpPropertyValue -InputObject $settings -Name @('intercom') -Default @{}
    $intercom = $state.Intercom
    $intercomEnabled = [bool](Get-DpPropertyValue -InputObject $intercomSettings -Name @('enabled') -Default $false)
    $intercomPrerequisites = [bool](Get-DpPropertyValue -InputObject $intercom -Name @('TokenConfigured') -Default $false) -and
        -not [string]::IsNullOrWhiteSpace([string](Get-DpPropertyValue -InputObject $intercomSettings -Name @('chatId') -Default ''))
    $intercomError = Protect-DpDiagnosticText -Text ([string](Get-DpPropertyValue -InputObject $intercom -Name @('LastError') -Default '')) -MaxLength 300
    $intercomHealthy = $intercomPrerequisites -and
        [bool](Get-DpPropertyValue -InputObject $intercom -Name @('Running') -Default $false) -and
        [string]::IsNullOrWhiteSpace($intercomError)

    $update = $state.Update
    $engineVersion = [string](Get-DpPropertyValue -InputObject $engine -Name @('Version') -Default '')
    if (-not $engineVersion -and $engine.ModulePath) {
        $parentLeaf = Split-Path -Path (Split-Path -Path ([string]$engine.ModulePath) -Parent) -Leaf
        if ($parentLeaf -match '^\d+\.\d+\.\d+') { $engineVersion = $parentLeaf }
    }

    [ordered]@{
        versions      = [ordered]@{
            deskPilot       = [string]$state.Version
            powerShell      = $PSVersionTable.PSVersion.ToString()
            engine          = $engineVersion
            git             = ''
            operatingSystem = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
        }
        paths         = [ordered]@{
            data   = [string]$state.DataDir
            module = [string]$engine.ModulePath
        }
        configuration = [ordered]@{
            valid           = $configurationValid
            settingCount    = $settingCount
            permissionCount = $permissionCount
        }
        project       = [ordered]@{
            configured = -not [string]::IsNullOrWhiteSpace($workspaceFolder)
            name       = (Protect-DpDiagnosticText -Text $projectName -MaxLength 100)
            path       = $workspaceFolder
        }
        engine        = [ordered]@{
            imported     = [bool]$engine.Imported
            authenticated = $(if ($engine.TokenPath) { Test-Path -LiteralPath $engine.TokenPath -PathType Leaf -ErrorAction SilentlyContinue } else { $false })
            importError   = (Protect-DpDiagnosticText -Text ([string]$engine.ImportError) -MaxLength 300)
        }
        mcp           = [ordered]@{
            supported      = [bool]$engine.McpSupported
            configuredCount = $configuredRows.Count
            enabledCount   = $enabledRows.Count
            observed       = $observationAvailable
            healthyCount   = $healthyCount
            degradedCount  = $degradedCount
            issue          = (Protect-DpDiagnosticText -Text $mcpIssue -MaxLength 240)
        }
        intercom      = [ordered]@{
            enabled   = $intercomEnabled
            available = $intercomPrerequisites
            healthy   = $intercomHealthy
            error     = $intercomError
        }
        browser       = [ordered]@{
            enabled = [bool](Get-DpPropertyValue -InputObject $permission -Name @('browserAutomation') -Default $false)
        }
        update        = [ordered]@{
            checked         = -not [string]::IsNullOrWhiteSpace([string](Get-DpPropertyValue -InputObject $update -Name @('checkedUtc') -Default ''))
            checking        = [bool](Get-DpPropertyValue -InputObject $update -Name @('checking') -Default $false)
            updateAvailable = [bool](Get-DpPropertyValue -InputObject $update -Name @('updateAvailable') -Default $false)
            targetVersion   = (Protect-DpDiagnosticText -Text ([string](Get-DpPropertyValue -InputObject $update -Name @('targetVersion') -Default '')) -MaxLength 80)
        }
    }
}