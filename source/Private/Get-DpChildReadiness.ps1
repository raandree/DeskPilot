function Get-DpChildReadiness {
    <#
    .SYNOPSIS
        Evaluates source-bound complete child readiness without side effects.
    .DESCRIPTION
        Separates implemented storage components from full child readiness.
        No Engine, Docker, network, setup, or cleanup operation is invoked.
    .PARAMETER Settings
        Current Settings used only to copy the effective policy.
    .PARAMETER Runtime
        Explicit prepared runtime record.
    .PARAMETER Proof
        Host operator proof record bound to current bytes and complete gates.
    .PARAMETER Health
        Recent read-only runtime health result.
    .PARAMETER CleanupBlocked
        An unresolved ownership or cleanup failure.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [hashtable]$Settings = @{},
        [AllowNull()][hashtable]$Runtime,
        [AllowNull()][hashtable]$Proof,
        [AllowNull()][hashtable]$Health,
        [switch]$CleanupBlocked
    )

    $missing = @('engine-request-admission', 'child-engine-process', 'child-approval-bridge', 'complete-run-resource-limits', 'authenticated-live-proof')
    $policy = $null
    try {
        $policy = ConvertTo-DpChildExecution -InputObject (Get-DpPropertyValue -InputObject $Settings -Name 'childExecution')
    }
    catch { $missing = @('valid-child-policy') + $missing }

    if ($policy -and $policy.profile -ceq 'single-child-v3') {
        $missing = [System.Collections.Generic.List[string]]::new()
        if (-not $Runtime -or $Runtime.schemaVersion -ne 2) { $missing.Add('prepared-complete-runtime') }
        if (-not $Proof -or $Proof.schemaVersion -ne 1 -or $Proof.profile -cne 'single-child-v3' -or
            $Proof.budgetMode -cne 'provider-estimate' -or $Proof.accepted -isnot [bool] -or -not $Proof.accepted -or
            $Proof.policyVersion -ne 3 -or $Proof.limitsVersion -ne 1) { $missing.Add('accepted-profile-proof') }
        if ($Proof) {
            foreach ($gate in @('engineFull', 'hostFull', 'actualRuntime', 'authenticatedLive', 'securityReview')) {
                if (-not $Proof.gates -or $Proof.gates[$gate] -isnot [bool] -or -not $Proof.gates[$gate]) { $missing.Add($gate) }
            }
            if ($null -eq $Proof.reviewBlockers -or $null -eq $Proof.reviewMajors -or
                $Proof.reviewBlockers -ne 0 -or $Proof.reviewMajors -ne 0) { $missing.Add('resolved-security-review') }
        }
        if ($Runtime -and $Proof) {
            try {
                if ($Proof.toolImage -cne $Runtime.image -or $Proof.engineImage -cne $Runtime.engineImage -or
                    $Proof.fingerprint -cne (Get-DpChildProfileFingerprint -Runtime $Runtime)) { $missing.Add('current-profile-fingerprint') }
            } catch { $missing.Add('current-profile-fingerprint') }
        }
        $checkedUtc = [datetime]::MinValue
        $validTime = $Health -and [datetime]::TryParse([string]$Health.checkedUtc, [ref]$checkedUtc)
        $healthAge = ([datetime]::UtcNow - $checkedUtc.ToUniversalTime()).TotalSeconds
        if (-not $Health -or $Health.ready -isnot [bool] -or -not $Health.ready -or
            -not $validTime -or $healthAge -lt 0 -or $healthAge -gt 300 -or
            $Health.toolImage -cne $Runtime.image -or $Health.engineImage -cne $Runtime.engineImage) { $missing.Add('current-runtime-health') }
        if ($CleanupBlocked -or -not $Health -or -not $Health.cleanupClear) { $missing.Add('verified-cleanup') }
        $ready = $missing.Count -eq 0
        return @{
            schemaVersion = 1; profile = $policy.profile; budgetMode = $policy.budgetMode; enabled = [bool]$policy.enabled
            ready = $ready; state = $(if ($ready) { 'ready' } elseif ($policy.enabled) { 'blocked' } else { 'disabled' })
            effectiveLimits = $policy; missingContracts = $missing.ToArray()
            message = $(if ($ready) { 'The current profile is proven. Each run still requires explicit selected-context and estimated-budget consent.' } else { 'Complete child execution is unavailable until current preparation, proof, review, health, and cleanup gates pass.' })
        }
    }

    @{
        schemaVersion = 1
        profile = 'single-child-v2'
        budgetMode = 'verified'
        enabled = ($null -ne $policy -and [bool]$policy.enabled)
        ready = $false
        state = if ($policy -and $policy.enabled) { 'blocked' } else { 'disabled' }
        effectiveLimits = $policy
        missingContracts = $missing
        message = 'Private Tool storage is available for explicit proof. Complete child execution is unavailable until Engine request admission, the credentialless Engine process, and child approvals are integrated and proven.'
    }
}
