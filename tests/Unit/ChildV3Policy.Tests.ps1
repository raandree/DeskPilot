BeforeAll {
    Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '../../source/Private') -Filter '*.ps1' | ForEach-Object { . $_.FullName }
}

Describe 'Explicit child V3 policy' {
    It 'keeps existing policies on disabled verified V2' {
        $policy = ConvertTo-DpChildExecution
        $policy.profile | Should -BeExactly 'single-child-v2'
        $policy.budgetMode | Should -BeExactly 'verified'
        $policy.enabled | Should -BeFalse
    }

    It 'requires the V3 profile and estimated budget mode together' {
        { ConvertTo-DpChildExecution -InputObject @{ profile = 'single-child-v3' } } | Should -Throw
        { ConvertTo-DpChildExecution -InputObject @{ budgetMode = 'provider-estimate' } } | Should -Throw
        $policy = ConvertTo-DpChildExecution -InputObject @{ profile = 'single-child-v3'; budgetMode = 'provider-estimate' }
        $policy.model | Should -BeExactly 'claude-haiku-4.5'
        $policy.requestBytes | Should -Be 262144
        $policy.enabled | Should -BeFalse
        $policy.maxRetries | Should -Be 0
        $policy.network | Should -BeExactly 'off'
    }

    It 'refuses unapproved Model and oversized serialized requests' {
        { ConvertTo-DpChildExecution -InputObject @{ profile = 'single-child-v3'; budgetMode = 'provider-estimate'; model = 'other' } } | Should -Throw
        { ConvertTo-DpChildExecution -InputObject @{ profile = 'single-child-v3'; budgetMode = 'provider-estimate'; requestBytes = 1048577 } } | Should -Throw
    }

    It 'refuses V3 buffers that cannot fit their reserved host storage partition' {
        { ConvertTo-DpChildExecution -InputObject @{
            profile = 'single-child-v3'; budgetMode = 'provider-estimate'
            storageBytes = 33554432; toolStorageBytes = 16777216
            baselineBytes = 1024; proposalBytes = 1024
            requestBytes = 1048576; outputBytes = 2097152
        } } | Should -Throw -ExpectedMessage '*buffers*'
    }
}
