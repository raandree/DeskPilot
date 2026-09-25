#requires -Version 7.0

Describe 'Compatibility Engine build artifact gate' {
    BeforeAll {
        Import-Module powershell-yaml -ErrorAction Stop
        $path = Join-Path $PSScriptRoot '..' '..' '.github' 'workflows' 'ci.yml'
        $workflow = Get-Content -LiteralPath $path -Raw | ConvertFrom-Yaml
        $step = @($workflow.jobs.build.steps | Where-Object name -eq 'Build compatibility Engine')
        $step | Should -HaveCount 1
        $script:compatibilityBuildStep = [scriptblock]::Create($step[0].run)
        $script:fixtureBuildParameters = @'
[CmdletBinding()]
param([switch]$ResolveDependency, [string[]]$Tasks, [string]$RequiredModulesDirectory, [string]$OutputDirectory)
'@
    }

    BeforeEach {
        $script:fixturePreviousRevision = $env:engineCompatibilityRevision
        $script:fixturePreviousExitCode = $global:LASTEXITCODE
        $env:engineCompatibilityRevision = 'fixture-revision'
        $fixtureRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $engineRoot = Join-Path $fixtureRoot '.compatibility-engine'
        $null = New-Item -ItemType Directory -Path $engineRoot
        $script:fixtureBuildPath = Join-Path $engineRoot 'build.ps1'
        Mock -CommandName git -MockWith { $global:LASTEXITCODE = 0; 'fixture-revision' }
        Push-Location -LiteralPath $fixtureRoot
    }

    AfterEach {
        Pop-Location
        $env:engineCompatibilityRevision = $script:fixturePreviousRevision
        $global:LASTEXITCODE = $script:fixturePreviousExitCode
    }

    It 'refuses a normally returning build that produces no Engine manifest' {
        Set-Content -LiteralPath $script:fixtureBuildPath -Value $script:fixtureBuildParameters
        { & $script:compatibilityBuildStep } | Should -Throw -ExpectedMessage '*manifest*'
    }

    It 'preserves a PowerShell build error rather than trusting the last native exit code' {
        $body = $script:fixtureBuildParameters + "`nWrite-Error 'Synthetic compatibility build failure.' -ErrorAction Stop"
        Set-Content -LiteralPath $script:fixtureBuildPath -Value $body
        { & $script:compatibilityBuildStep } | Should -Throw -ExpectedMessage '*Synthetic compatibility build failure*'
    }

    It 'accepts a successful build with exactly one Engine manifest' {
        $body = $script:fixtureBuildParameters + "`n" + @'
$moduleRoot = Join-Path $OutputDirectory 'module' 'ShellPilot' '0.0.1'
$null = New-Item -ItemType Directory -Path $moduleRoot
Set-Content -LiteralPath (Join-Path $moduleRoot 'ShellPilot.psd1') -Value '@{}'
'@
        Set-Content -LiteralPath $script:fixtureBuildPath -Value $body
        { & $script:compatibilityBuildStep } | Should -Not -Throw
        Should -Invoke -CommandName git -Exactly -Times 1
    }
}
