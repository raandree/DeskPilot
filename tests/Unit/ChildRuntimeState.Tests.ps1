BeforeAll {
    Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '../../source/Private') -Filter '*.ps1' |
        ForEach-Object { . $_.FullName }
}

Describe 'Child runtime state' {
    It 'does not prepare, authenticate, or enable a missing runtime on startup' {
        (Get-Command Initialize-DpChildState -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        Mock Invoke-DpDockerControl { throw 'No prepared runtime.' }
        $state = Initialize-DpChildState -DataDirectory $TestDrive
        $state.Runtime | Should -BeNullOrEmpty
        $state.Proof | Should -BeNullOrEmpty
        $state.CleanupBlocked | Should -BeFalse
        Should -Invoke Invoke-DpDockerControl -Times 0 -Exactly
    }

    It 'reports only immutable image and backend health without reading credentials' {
        (Get-Command Get-DpChildRuntimeHealth -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        $runtime = @{ image = ('sha256:' + ('a' * 64)); engineImage = ('sha256:' + ('b' * 64)) }
        Mock Invoke-DpDockerControl {
            switch ($Argument[0]) {
                'info' { '{"OSType":"linux","CgroupVersion":"2","MemoryLimit":true,"CpuCfsQuota":true,"PidsLimit":true,"ServerVersion":"fixture"}' }
                'image' { $Argument[2] }
                'ps' { '' }
                default { throw 'No mutations permitted.' }
            }
        }
        $health = Get-DpChildRuntimeHealth -Runtime $runtime -DataDirectory $TestDrive
        $health.ready | Should -BeTrue
        $health.cleanupClear | Should -BeTrue
        $health.toolImage | Should -BeExactly $runtime.image
        $health.engineImage | Should -BeExactly $runtime.engineImage
    }

    It 'keeps admission blocked when startup reconciliation cannot verify cleanup' {
        (Get-Command Initialize-DpChildState -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        $directory = Join-Path $TestDrive 'uncertain'
        $null = New-Item -Path (Join-Path $directory 'child-runs') -ItemType Directory -Force
        Mock Remove-DpChildRun { throw 'Uncertain cleanup.' }
        $state = Initialize-DpChildState -DataDirectory $directory
        $state.CleanupBlocked | Should -BeTrue
        $state.Error | Should -BeExactly 'child-cleanup-unresolved'
    }
}
