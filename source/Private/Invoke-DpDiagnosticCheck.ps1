function Invoke-DpDiagnosticCheck {
    <#
    .SYNOPSIS
        Runs DeskPilot's deterministic, read-only self-check.
    .DESCRIPTION
        Inspects configuration facts, local paths, and the local Git executable.
        Engine, MCP, Intercom, and Update states come from the allow-listed
        snapshot captured by the Host Server. This function never invokes a Model,
        calls the Engine, writes a file, or performs a network request.
    .PARAMETER Snapshot
        Allow-listed Host Server facts with no secret values or Message content.
    .PARAMETER TimeoutMilliseconds
        Per-probe wall-clock deadline.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [object]$Snapshot,

        [ValidateRange(50, 30000)]
        [int]$TimeoutMilliseconds = 1500
    )

    $started = [datetime]::UtcNow
    $checks = [System.Collections.Generic.List[object]]::new()
    $add = { param($Check) $checks.Add($Check) }

    $configurationState = Resolve-DpDiagnosticState -Healthy:([bool]$Snapshot.configuration.valid)
    & $add (New-DpDiagnosticCheck -Id 'configuration' -Label 'Configuration' -State $configurationState `
            -Explanation $(if ($configurationState -eq 'healthy') { 'The saved configuration shape is valid.' } else { 'The saved configuration shape could not be validated.' }) `
            -Action $(if ($configurationState -eq 'healthy') { '' } else { 'Open Settings and save the affected values again.' }))

    $pathProbe = {
        param([string]$Path, [string]$Description)
        if ([string]::IsNullOrWhiteSpace($Path)) {
            return @{ state = 'unavailable'; explanation = "$Description has no resolved path."; action = 'Restart DeskPilot and run the self-check again.' }
        }
        if (Test-Path -LiteralPath $Path) {
            return @{ state = 'healthy'; explanation = "$Description is available."; action = '' }
        }
        @{ state = 'unavailable'; explanation = "$Description could not be found."; action = 'Verify the path or reinstall the missing component.' }
    }
    & $add (Invoke-DpDiagnosticProbe -Id 'data-path' -Label 'Data path' -Probe $pathProbe `
            -Argument @([string]$Snapshot.paths.data, 'The DeskPilot data directory') `
            -TimeoutMilliseconds $TimeoutMilliseconds -TimeoutAction 'Verify the data directory directly.')
    & $add (Invoke-DpDiagnosticProbe -Id 'engine-module' -Label 'Engine module path' -Probe $pathProbe `
            -Argument @([string]$Snapshot.paths.module, 'The Engine module') `
            -TimeoutMilliseconds $TimeoutMilliseconds -TimeoutAction 'Verify the Engine module path directly.')

    if (-not [bool]$Snapshot.project.configured) {
        & $add (New-DpDiagnosticCheck -Id 'project' -Label 'Active Project' -State 'not configured' `
                -Explanation 'No Project is selected.' -Action 'Select a Project when you want DeskPilot to work in a folder.')
    }
    else {
        & $add (Invoke-DpDiagnosticProbe -Id 'project' -Label 'Active Project' -Probe $pathProbe `
                -Argument @([string]$Snapshot.project.path, 'The selected Project folder') `
                -TimeoutMilliseconds $TimeoutMilliseconds -TimeoutAction 'Verify the Project folder directly.')
    }

    $engineState = Resolve-DpDiagnosticState -Available:([bool]$Snapshot.engine.imported) -Healthy:([bool]$Snapshot.engine.imported)
    & $add (New-DpDiagnosticCheck -Id 'engine' -Label 'Engine' -State $engineState `
            -Explanation $(if ($engineState -eq 'healthy') { 'The Engine is loaded.' } else { "The Engine is not loaded: $($Snapshot.engine.importError)" }) `
            -Action $(if ($engineState -eq 'healthy') { '' } else { 'Reinstall ShellPilot or correct the configured Engine module path.' }) `
            -Detail @{ version = [string]$Snapshot.versions.engine })

    $authAvailable = [bool]$Snapshot.engine.imported
    $authHealthy = $authAvailable -and [bool]$Snapshot.engine.authenticated
    $authState = Resolve-DpDiagnosticState -Available:$authAvailable -Healthy:$authHealthy
    & $add (New-DpDiagnosticCheck -Id 'engine-auth' -Label 'Engine authentication' -State $authState `
            -Explanation $(if ($authState -eq 'healthy') { 'A cached Engine sign-in is present.' } elseif ($authState -eq 'unavailable') { 'Authentication cannot be checked while the Engine is unavailable.' } else { 'No cached Engine sign-in is present.' }) `
            -Action $(if ($authState -eq 'healthy') { '' } else { 'Use Re-authenticate in Settings.' }))

    $gitProbe = {
        $command = Get-Command -Name git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $command) {
            return @{ state = 'unavailable'; explanation = 'Git is not installed or not on PATH.'; action = 'Install Git or add it to PATH.'; version = '' }
        }
        $text = @(& $command.Source --version 2>&1) -join ' '
        if ($LASTEXITCODE -ne 0) {
            return @{ state = 'degraded'; explanation = 'Git was found but did not report its version.'; action = 'Run git --version in a terminal.'; version = '' }
        }
        @{ state = 'healthy'; explanation = 'Git is available.'; action = ''; version = ($text -replace '^git version\s+', '').Trim() }
    }
    $git = Invoke-DpDiagnosticProbe -Id 'git' -Label 'Git' -Probe $gitProbe `
        -TimeoutMilliseconds $TimeoutMilliseconds -TimeoutAction 'Run git --version in a terminal.'
    & $add $git
    if ($git.PSObject.Properties['version']) { $Snapshot.versions.git = [string]$git.version }

    $mcpConfigured = [int]$Snapshot.mcp.enabledCount -gt 0
    $mcpAvailable = [bool]$Snapshot.mcp.supported -and [bool]$Snapshot.mcp.observed
    $mcpHealthy = $mcpAvailable -and [int]$Snapshot.mcp.degradedCount -eq 0 -and
        [int]$Snapshot.mcp.healthyCount -ge [int]$Snapshot.mcp.enabledCount
    $mcpState = Resolve-DpDiagnosticState -Configured:$mcpConfigured -Available:$mcpAvailable -Healthy:$mcpHealthy
    $mcpIssue = Protect-DpDiagnosticText `
        -Text ([string](Get-DpPropertyValue -InputObject $Snapshot.mcp -Name @('issue') -Default '')) `
        -MaxLength 240
    $mcpExplanation = switch ($mcpState) {
        'healthy' { 'Every enabled MCP server was healthy when last inspected.' }
        'degraded' { $(if ($mcpIssue) { "An enabled MCP server reported: $mcpIssue" } else { 'One or more enabled MCP servers were not healthy when last inspected.' }) }
        'unavailable' { $(if (-not $Snapshot.mcp.supported) { 'The loaded Engine does not support MCP servers.' } elseif ($mcpIssue) { "MCP server state could not be inspected: $mcpIssue" } else { 'No live MCP server observation is available.' }) }
        default { 'No MCP server is enabled.' }
    }
    $mcpAction = switch ($mcpState) {
        'degraded' { 'Open MCP servers in Settings and refresh the affected server.' }
        'unavailable' { 'Open MCP servers in Settings and inspect or update the Engine.' }
        'not configured' { 'Attach an MCP server only when you need its Tools.' }
        default { '' }
    }
    & $add (New-DpDiagnosticCheck -Id 'mcp' -Label 'MCP servers' -State $mcpState `
            -Explanation $mcpExplanation -Action $mcpAction -Detail @{
                configuredCount = [int]$Snapshot.mcp.configuredCount
                enabledCount = [int]$Snapshot.mcp.enabledCount
                healthyCount = [int]$Snapshot.mcp.healthyCount
                degradedCount = [int]$Snapshot.mcp.degradedCount
            })

    $intercomState = Resolve-DpDiagnosticState -Configured:([bool]$Snapshot.intercom.enabled) `
        -Available:([bool]$Snapshot.intercom.available) -Healthy:([bool]$Snapshot.intercom.healthy)
    & $add (New-DpDiagnosticCheck -Id 'intercom' -Label 'Intercom' -State $intercomState `
            -Explanation $(switch ($intercomState) {
                    'healthy' { 'Intercom is connected.' }
                    'degraded' { "Intercom reported a problem: $($Snapshot.intercom.error)" }
                    'unavailable' { 'Intercom is enabled but is not ready.' }
                    default { 'Intercom is off.' }
                }) `
            -Action $(switch ($intercomState) {
                    'degraded' { 'Open Intercom in Settings and inspect its status.' }
                    'unavailable' { 'Finish the Intercom token and phone setup.' }
                    'not configured' { 'Turn on Intercom only when phone access is needed.' }
                    default { '' }
                }))

    $updateState = if ([bool]$Snapshot.update.checking) { 'degraded' }
        elseif (-not [bool]$Snapshot.update.checked) { 'unavailable' }
        else { 'healthy' }
    & $add (New-DpDiagnosticCheck -Id 'update' -Label 'Update status' -State $updateState `
            -Explanation $(if ($updateState -eq 'healthy') {
                    if ($Snapshot.update.updateAvailable) { "DeskPilot $($Snapshot.update.targetVersion) is available." } else { 'The latest completed Update check found no newer version.' }
                } elseif ($updateState -eq 'degraded') { 'An Update check is still running.' } else { 'No completed Update check is available.' }) `
            -Action $(if ($updateState -eq 'healthy') { '' } else { 'Use Check for updates in Settings.' }))

    $states = @($checks | ForEach-Object { $_.state })
    $overall = if ($states -contains 'unavailable') { 'unavailable' }
        elseif ($states -contains 'degraded') { 'degraded' }
        else { 'healthy' }
    @{
        startedUtc   = $started.ToString('o')
        completedUtc = [datetime]::UtcNow.ToString('o')
        overallState = $overall
        versions     = $Snapshot.versions
        checks       = $checks.ToArray()
    }
}