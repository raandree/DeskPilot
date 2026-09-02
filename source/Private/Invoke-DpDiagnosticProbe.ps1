function Invoke-DpDiagnosticProbe {
    <#
    .SYNOPSIS
        Runs one read-only diagnostic probe under a wall-clock deadline.
    .DESCRIPTION
        Uses an isolated PowerShell instance so a slow local dependency can be
        stopped without holding the caller indefinitely. The probe returns a
        diagnostic check shape; failures and timeouts are always reported as
        degraded rather than guessed healthy.
    .PARAMETER Id
        Stable check identifier.
    .PARAMETER Label
        Human-readable dependency name.
    .PARAMETER Probe
        Read-only probe script block.
    .PARAMETER Argument
        Positional arguments passed to the probe.
    .PARAMETER TimeoutMilliseconds
        Wall-clock deadline for the probe.
    .PARAMETER TimeoutAction
        Safe next action after a timeout.
    .PARAMETER FailureAction
        Safe next action after a probe exception.
    .OUTPUTS
        System.Collections.Specialized.OrderedDictionary
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [string]$Id,

        [Parameter(Mandatory)]
        [string]$Label,

        [Parameter(Mandatory)]
        [scriptblock]$Probe,

        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Argument = @(),

        [ValidateRange(50, 30000)]
        [int]$TimeoutMilliseconds = 1500,

        [AllowEmptyString()]
        [string]$TimeoutAction = 'Try the check again.',

        [AllowEmptyString()]
        [string]$FailureAction = 'Inspect the dependency manually.'
    )

    $shell = [powershell]::Create()
    $async = $null
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $null = $shell.AddScript($Probe.ToString())
        foreach ($item in @($Argument)) { $null = $shell.AddArgument($item) }
        $async = $shell.BeginInvoke()
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMilliseconds)) {
            try {
                $stop = $shell.BeginStop($null, $null)
                $null = $stop.AsyncWaitHandle.WaitOne(250)
            }
            catch { $null = $_ }
            return New-DpDiagnosticCheck -Id $Id -Label $Label -State 'degraded' `
                -Explanation "$Label did not finish within $TimeoutMilliseconds ms, so its state could not be inspected." `
                -Action $TimeoutAction
        }

        $output = @($shell.EndInvoke($async))
        if ($shell.HadErrors) {
            $failure = $shell.Streams.Error | Select-Object -First 1
            throw $(if ($failure) { $failure.Exception } else { [System.InvalidOperationException]::new('The probe failed.') })
        }
        $value = $output | Select-Object -Last 1
        if (-not $value) {
            return New-DpDiagnosticCheck -Id $Id -Label $Label -State 'degraded' `
                -Explanation "$Label returned no inspection result." -Action $FailureAction
        }

        $read = {
            param($Object, [string]$Name, $Default)
            if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($Name)) { return $Object[$Name] }
            $property = $Object.PSObject.Properties[$Name]
            if ($property) { return $property.Value }
            $Default
        }
        $state = [string](& $read $value 'state' 'degraded')
        if ($state -notin @('healthy', 'degraded', 'unavailable', 'not configured')) { $state = 'degraded' }
        $detail = @{}
        foreach ($key in 'version', 'configuredCount', 'enabledCount', 'healthyCount', 'degradedCount') {
            $item = & $read $value $key $null
            if ($null -ne $item) { $detail[$key] = $item }
        }
        New-DpDiagnosticCheck -Id $Id -Label $Label -State $state `
            -Explanation ([string](& $read $value 'explanation' "$Label was inspected.")) `
            -Action ([string](& $read $value 'action' '')) -Detail $detail
    }
    catch {
        $probeError = $_
        New-DpDiagnosticCheck -Id $Id -Label $Label -State 'degraded' `
            -Explanation "$Label could not be inspected: $($probeError.Exception.Message)" `
            -Action $FailureAction
    }
    finally {
        $stopwatch.Stop()
        if ($async) { try { $async.AsyncWaitHandle.Dispose() } catch { $null = $_ } }
        try { $shell.Dispose() } catch { $null = $_ }
    }
}