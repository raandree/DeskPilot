function Get-DpChildReadiness {
    <#
    .SYNOPSIS
        Reports the incomplete single-child execution profile without side effects.
    .DESCRIPTION
        Separates implemented storage components from full child readiness.
        No Engine, Docker, network, setup, or cleanup operation is invoked.
    .PARAMETER Settings
        Current Settings used only to copy the effective policy.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([hashtable]$Settings = @{})

    $missing = @('engine-request-admission', 'child-engine-process', 'child-approval-bridge', 'complete-run-resource-limits', 'authenticated-live-proof')
    $policy = $null
    try {
        $policy = ConvertTo-DpChildExecution -InputObject (Get-DpPropertyValue -InputObject $Settings -Name 'childExecution')
    }
    catch { $missing = @('valid-child-policy') + $missing }

    @{
        schemaVersion = 1
        profile = 'single-child-v2'
        enabled = ($null -ne $policy -and [bool]$policy.enabled)
        ready = $false
        state = if ($policy -and $policy.enabled) { 'blocked' } else { 'disabled' }
        effectiveLimits = $policy
        missingContracts = $missing
        message = 'Private Tool storage is available for explicit proof. Complete child execution is unavailable until Engine request admission, the credentialless Engine process, and child approvals are integrated and proven.'
    }
}
