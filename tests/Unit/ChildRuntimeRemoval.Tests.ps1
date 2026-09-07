BeforeAll {
    Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '../../source/Private') -Filter '*.ps1' |
        ForEach-Object { . $_.FullName }
}

Describe 'Owned child runtime removal' {
    BeforeEach {
        $script:directory = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:runtimeRoot = Join-Path $script:directory 'child-runtime'
        $null = New-Item -Path $script:runtimeRoot -ItemType Directory -Force
        $script:runtime = @{
            image = ('sha256:' + ('a' * 64)); tag = ('deskpilot-child:' + ('b' * 32))
            engineImage = ('sha256:' + ('c' * 64)); engineTag = ('deskpilot-child-engine:' + ('d' * 32))
        }
        $script:runtime | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:runtimeRoot 'runtime.json')
        Mock Remove-DpChildRun { @{ removed = 1; retained = 0 } }
        Mock Invoke-DpDockerControl {
            if ($Argument[1] -eq 'inspect') {
                if ($Argument[2] -ceq $script:runtime.tag) { return $script:runtime.image }
                if ($Argument[2] -ceq $script:runtime.engineTag) { return $script:runtime.engineImage }
            }
            if ($Argument[1] -eq 'rm') { return '' }
            throw 'Unexpected shared runtime operation.'
        }
    }

    It 'removes only verified child image tags after owned-run cleanup' {
        (Get-Command Uninstall-DpChildRuntime -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        $result = Uninstall-DpChildRuntime -DataDirectory $script:directory -Confirm:$false
        $result.removed | Should -BeTrue
        Test-Path -LiteralPath $script:runtimeRoot | Should -BeFalse
        Should -Invoke Remove-DpChildRun -Times 1 -Exactly -ParameterFilter { $DiscardCompleted }
        Should -Invoke Invoke-DpDockerControl -Times 2 -Exactly -ParameterFilter { $Argument[0] -eq 'image' -and $Argument[1] -eq 'rm' }
    }

    It 'refuses an image tag outside the positively owned child naming contract' {
        (Get-Command Uninstall-DpChildRuntime -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        $script:runtime.tag = 'shared-image:latest'
        $script:runtime | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:runtimeRoot 'runtime.json')
        { Uninstall-DpChildRuntime -DataDirectory $script:directory -Confirm:$false } | Should -Throw
        Should -Invoke Invoke-DpDockerControl -Times 0 -Exactly -ParameterFilter { $Argument[1] -eq 'rm' }
        Test-Path -LiteralPath $script:runtimeRoot | Should -BeTrue
    }
}
