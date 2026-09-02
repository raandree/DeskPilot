function Start-DpDiagnosticCheck {
    <#
    .SYNOPSIS
        Starts the deterministic self-check away from the accept loop.
    .DESCRIPTION
        Captures or accepts an allow-listed snapshot and runs the read-only worker
        in a background job. The route returns immediately and the idle loop reaps
        the result through Update-DpDiagnosticCheckState.
    .PARAMETER Snapshot
        Optional prebuilt allow-listed snapshot, primarily for tests.
    .PARAMETER TimeoutMilliseconds
        Per-probe timeout passed to the worker.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Starts a read-only background inspection and updates transient Host Server state.')]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseUsingScopeModifierInNewRunspaces', '', Justification = 'The job receives a self-contained payload through param() and -ArgumentList.')]
    param(
        [object]$Snapshot,

        [ValidateRange(50, 30000)]
        [int]$TimeoutMilliseconds = 1500
    )

    $diagnostics = $script:DeskPilot.Diagnostics
    if ($diagnostics.CheckJob -and $diagnostics.CheckJob.State -in @('NotStarted', 'Running')) {
        return @{ started = $false; alreadyRunning = $true }
    }

    if (-not $PSBoundParameters.ContainsKey('Snapshot') -or $null -eq $Snapshot) {
        $Snapshot = New-DpDiagnosticSnapshot
    }

    $names = @(
        'Get-DpPropertyValue', 'Hide-DpIntercomSecret', 'Protect-DpDiagnosticText',
        'Resolve-DpDiagnosticState', 'New-DpDiagnosticCheck',
        'Invoke-DpDiagnosticProbe', 'Invoke-DpDiagnosticCheck'
    )
    $definitions = @($names | ForEach-Object {
            @{ name = $_; definition = (Get-Command -Name $_ -CommandType Function -ErrorAction Stop).Definition }
        })
    $payload = @{ definitions = $definitions; snapshot = $Snapshot; timeoutMilliseconds = $TimeoutMilliseconds }

    try {
        $job = Start-Job -ScriptBlock {
            param($Payload)
            foreach ($definition in @($Payload.definitions)) {
                $name = [string]$definition.name
                $body = [string]$definition.definition
                . ([scriptblock]::Create("function $name { $body }"))
            }
            Invoke-DpDiagnosticCheck -Snapshot $Payload.snapshot -TimeoutMilliseconds ([int]$Payload.timeoutMilliseconds)
        } -ArgumentList $payload
        $diagnostics.CheckJob = $job
        $diagnostics.Checking = $true
        $diagnostics.CheckStartedUtc = [datetime]::UtcNow.ToString('o')
        if ($diagnostics.Log) {
            Add-DpDiagnosticLog -Log $diagnostics.Log -Severity 'information' -Component 'diagnostics' `
                -EventId 'self-check.started' -Summary 'The deterministic self-check started.'
        }
        @{ started = $true; alreadyRunning = $false }
    }
    catch {
        $startError = Protect-DpDiagnosticText -Text "$($_.Exception.Message)"
        $diagnostics.CheckJob = $null
        $diagnostics.Checking = $false
        if ($diagnostics.Log) {
            Add-DpDiagnosticLog -Log $diagnostics.Log -Severity 'error' -Component 'diagnostics' `
                -EventId 'self-check.start-failed' -Summary $startError
        }
        @{ started = $false; alreadyRunning = $false; error = $startError }
    }
}