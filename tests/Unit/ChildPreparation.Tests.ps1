BeforeAll {
    Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '../../source/Private') -Filter '*.ps1' |
        ForEach-Object { . $_.FullName }
}

Describe 'Explicit child preparation' {
    BeforeEach {
        $script:prior = $script:DeskPilot
        $script:DeskPilot = @{
            TurnRunning = $false; DataDir = $TestDrive; Engine = @{ ModulePath = 'approved-engine' }
            Settings = Get-DpDefaultSettings
            Child = @{ SetupJob = $null; Controller = $null; Runtime = $null; Proof = $null; Health = $null; CleanupBlocked = $false; Error = '' }
        }
        Mock Start-Job { [pscustomobject]@{ State = 'Running'; Id = 1 } }
    }

    AfterEach { $script:DeskPilot = $script:prior }

    It 'prepares only on explicit request and passes the selected Engine without enabling children' {
        (Get-Command Start-DpChildPreparation -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        Start-DpChildPreparation -Action prepare | Should -BeTrue
        Should -Invoke Start-Job -Times 1 -Exactly -ParameterFilter { $ArgumentList[0].engine -ceq 'approved-engine' -and $ArgumentList[0].action -ceq 'prepare' }
        $script:DeskPilot.Settings.childExecution.enabled | Should -BeFalse
    }

    It 'refuses preparation while an active Turn owns execution' {
        (Get-Command Start-DpChildPreparation -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        $script:DeskPilot.TurnRunning = $true
        { Start-DpChildPreparation -Action prepare } | Should -Throw
        Should -Invoke Start-Job -Times 0 -Exactly
    }

    It 'does not run concurrent preparation operations' {
        (Get-Command Start-DpChildPreparation -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        $script:DeskPilot.Child.SetupJob = [pscustomobject]@{ State = 'Running'; Id = 1 }
        Start-DpChildPreparation -Action check | Should -BeFalse
        Should -Invoke Start-Job -Times 0 -Exactly
    }
}
