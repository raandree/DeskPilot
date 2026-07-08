#requires -Version 7.0

BeforeAll {
    $script:moduleName = 'DeskPilot'

    # Ensure the built module is available; the noop task sets up the environment.
    if (-not (Get-Module -Name $script:moduleName -ListAvailable))
    {
        & "$PSScriptRoot/../../../build.ps1" -Tasks 'noop' 2>&1 4>&1 5>&1 6>&1 > $null
    }

    Import-Module -Name $script:moduleName -Force -ErrorAction 'Stop'
}

AfterAll {
    Remove-Module -Name $script:moduleName -Force -ErrorAction SilentlyContinue
}

Describe 'Start-DeskPilot' -Tag 'Unit' {
    Context 'Command surface' {
        It 'Should be exported from the module' {
            Get-Command -Name 'Start-DeskPilot' -Module $script:moduleName | Should -Not -BeNullOrEmpty
        }

        It 'Should expose the expected parameters' {
            $command = Get-Command -Name 'Start-DeskPilot' -Module $script:moduleName
            foreach ($parameterName in 'Port', 'EngineModulePath', 'DataDir', 'NoBrowser')
            {
                $command.Parameters.Keys | Should -Contain $parameterName
            }
        }

        It 'Should not expose a public -WebRoot parameter (the web root is resolved internally)' {
            $command = Get-Command -Name 'Start-DeskPilot' -Module $script:moduleName
            $command.Parameters.Keys | Should -Not -Contain 'WebRoot'
        }
    }
}
