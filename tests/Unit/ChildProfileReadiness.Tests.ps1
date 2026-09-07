BeforeAll {
    Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '../../source/Private') -Filter '*.ps1' |
        ForEach-Object { . $_.FullName }
}

Describe 'Source-bound complete child readiness' {
    BeforeEach {
        $script:settings = Get-DpDefaultSettings
        $script:settings.childExecution = ConvertTo-DpChildExecution -InputObject @{
            enabled = $true; profile = 'single-child-v3'; budgetMode = 'provider-estimate'
        }
        $script:runtime = @{ schemaVersion = 2; image = ('sha256:' + ('a' * 64)); engineImage = ('sha256:' + ('b' * 64)) }
        $script:proof = @{
            schemaVersion = 1; profile = 'single-child-v3'; budgetMode = 'provider-estimate'; accepted = $true
            fingerprint = 'c' * 64; toolImage = $script:runtime.image; engineImage = $script:runtime.engineImage
            policyVersion = 3; limitsVersion = 1; reviewBlockers = 0; reviewMajors = 0
            gates = @{ engineFull = $true; hostFull = $true; actualRuntime = $true; authenticatedLive = $true; securityReview = $true }
        }
        $script:health = @{ ready = $true; checkedUtc = [datetime]::UtcNow.ToString('o'); toolImage = $script:runtime.image; engineImage = $script:runtime.engineImage; cleanupClear = $true }
    }

    It 'requires every current gate and never enables Settings as a side effect' {
        (Get-Command Get-DpChildProfileFingerprint -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        Mock Get-DpChildProfileFingerprint { 'c' * 64 }
        $script:settings.childExecution.enabled = $false
        $before = $script:settings | ConvertTo-Json -Depth 12 -Compress
        $ready = Get-DpChildReadiness -Settings $script:settings -Runtime $script:runtime -Proof $script:proof -Health $script:health
        $ready.ready | Should -BeTrue
        $ready.enabled | Should -BeFalse
        $ready.profile | Should -BeExactly 'single-child-v3'
        $ready.budgetMode | Should -BeExactly 'provider-estimate'
        ($script:settings | ConvertTo-Json -Depth 12 -Compress) | Should -BeExactly $before
    }

    It 'invalidates readiness for <Case>' -ForEach @(
        @{ Case = 'changed source'; Target = 'proof'; Field = 'fingerprint'; Value = ('d' * 64) }
        @{ Case = 'replaced image'; Target = 'runtime'; Field = 'engineImage'; Value = ('sha256:' + ('d' * 64)) }
        @{ Case = 'stale health'; Target = 'health'; Field = 'checkedUtc'; Value = '2000-01-01T00:00:00Z' }
        @{ Case = 'missing acceptance'; Target = 'proof'; Field = 'accepted'; Value = $false }
        @{ Case = 'unresolved review'; Target = 'proof'; Field = 'reviewMajors'; Value = 1 }
        @{ Case = 'incomplete live proof'; Target = 'gates'; Field = 'authenticatedLive'; Value = $false }
        @{ Case = 'cleanup not clear'; Target = 'health'; Field = 'cleanupClear'; Value = $false }
    ) {
        (Get-Command Get-DpChildProfileFingerprint -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        Mock Get-DpChildProfileFingerprint { 'c' * 64 }
        switch ($Target) {
            'proof' { $script:proof[$Field] = $Value }
            'runtime' { $script:runtime[$Field] = $Value }
            'health' { $script:health[$Field] = $Value }
            'gates' { $script:proof.gates[$Field] = $Value }
        }
        $ready = Get-DpChildReadiness -Settings $script:settings -Runtime $script:runtime -Proof $script:proof -Health $script:health
        $ready.ready | Should -BeFalse
        $ready.missingContracts | Should -Not -BeNullOrEmpty
    }
}
