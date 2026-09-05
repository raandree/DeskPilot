function Get-DpDiagnosticPayload {
    <#
    .SYNOPSIS
        Builds the read-only Diagnostics API payload.
    .DESCRIPTION
        Projects current facts, the latest self-check, and a bounded log snapshot
        into a fresh allow-listed object. The two absolute paths are retained
        because the Diagnostics view explicitly reports the resolved data and
        Engine module paths; support-bundle records use path purpose and leaf only.
    .PARAMETER AfterSequence
        Return log entries newer than this polling cursor.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [ValidateRange(0, [long]::MaxValue)]
        [long]$AfterSequence = 0
    )

    try { Update-DpDiagnosticCheckState } catch { $null = $_ }
    $snapshot = New-DpDiagnosticSnapshot
    $diagnostics = $script:DeskPilot.Diagnostics
    $log = $diagnostics.Log

    [System.Threading.Monitor]::Enter($log.SyncRoot)
    try {
        $entries = @($log.Entries | Where-Object { [long]$_.sequence -gt $AfterSequence })
        $logCount = $log.Entries.Count
        $logBytes = [long]$log.CurrentBytes
        $latestSequence = [long]$log.NextSequence
    }
    finally {
        [System.Threading.Monitor]::Exit($log.SyncRoot)
    }

    $lastCheck = $diagnostics.LastCheck
    $versions = if ($lastCheck) {
        Get-DpPropertyValue -InputObject $lastCheck -Name @('versions') -Default $snapshot.versions
    }
    else { $snapshot.versions }
    $dataLeaf = if ($snapshot.paths.data) { Split-Path -Path $snapshot.paths.data -Leaf } else { '' }
    $moduleLeaf = if ($snapshot.paths.module) { Split-Path -Path $snapshot.paths.module -Leaf } else { '' }

    @{
        generatedUtc = [datetime]::UtcNow.ToString('o')
        overallState = $(if ($lastCheck) { [string](Get-DpPropertyValue -InputObject $lastCheck -Name @('overallState') -Default 'degraded') } else { 'unavailable' })
        versions     = $versions
        paths        = @{
            data = @{ purpose = 'DeskPilot data'; leaf = $dataLeaf; path = [string]$snapshot.paths.data; absolute = $true }
            module = @{ purpose = 'Engine module'; leaf = $moduleLeaf; path = [string]$snapshot.paths.module; absolute = $true }
        }
        project      = @{
            configured = [bool]$snapshot.project.configured
            name = [string]$snapshot.project.name
            folderLeaf = $(if ($snapshot.project.path) { Split-Path -Path $snapshot.project.path -Leaf } else { '' })
        }
        configuration = @{
            valid = [bool]$snapshot.configuration.valid
            settingCount = [int]$snapshot.configuration.settingCount
            permissionCount = [int]$snapshot.configuration.permissionCount
            mcpServerCount = [int]$snapshot.mcp.configuredCount
            intercomEnabled = [bool]$snapshot.intercom.enabled
        }
        terminalExecution = Get-DpTerminalStatus
        selfCheck    = @{
            checking = [bool]$diagnostics.Checking
            startedUtc = $diagnostics.CheckStartedUtc
            lastRunUtc = $diagnostics.LastCheckUtc
            checks = @($(if ($lastCheck) { Get-DpPropertyValue -InputObject $lastCheck -Name @('checks') -Default @() } else { @() }))
        }
        logs         = @{
            entries = $entries
            count = $logCount
            bytes = $logBytes
            latestSequence = $latestSequence
            retention = @{
                maxEntries = [int]$log.MaxEntries
                maxBytes = [long]$log.MaxBytes
                persistent = $false
                clearedOnRestart = $true
            }
        }
        supportBundle = @{
            exporting = [bool]$diagnostics.Exporting
            lastExport = $(if ($diagnostics.LastExport) {
                    @{
                        path = [string](Get-DpPropertyValue -InputObject $diagnostics.LastExport -Name @('path') -Default '')
                        createdUtc = [string](Get-DpPropertyValue -InputObject $diagnostics.LastExport -Name @('createdUtc') -Default '')
                        bytes = [long](Get-DpPropertyValue -InputObject $diagnostics.LastExport -Name @('bytes') -Default 0)
                    }
                } else { $null })
        }
    }
}