#requires -Version 7.0

BeforeAll {
    $privateRoot = Join-Path $PSScriptRoot '..' '..' 'source' 'Private'
    Get-ChildItem -Path $privateRoot -Filter '*.ps1' | ForEach-Object { . $_.FullName }

    function Get-RouteJson {
        $response = [System.Text.Encoding]::UTF8.GetString($script:responseStream.ToArray())
        $response -split "`r`n`r`n", 2 | Select-Object -Last 1 | ConvertFrom-Json
    }
}

Describe 'models route default resolution' -Tag 'Unit' {
    BeforeEach {
        $script:DeskPilot = @{
            Settings       = @{ model = $null }
            Models         = @()
            PreferredModel = 'claude-opus-5'
            DefaultModel   = 'claude-opus-5'
        }
        $script:responseStream = [System.IO.MemoryStream]::new()
    }

    AfterEach {
        $script:responseStream.Dispose()
        $script:DeskPilot = $null
    }

    It 'reports the preferred Model as the default when the Engine advertises it' {
        Mock Invoke-DpEngineCommand -ParameterFilter { $Command -eq 'Get-ShpModel' } -MockWith {
            @(
                [pscustomobject]@{ Id = 'claude-opus-4.6'; MaxContextWindowTokens = 200000; ReasoningEfforts = @() }
                [pscustomobject]@{ Id = 'claude-opus-5'; MaxContextWindowTokens = 200000; ReasoningEfforts = @('low', 'high') }
            )
        }
        Mock Invoke-DpEngineCommand -ParameterFilter { $Command -eq 'Get-ShpDefault' } -MockWith { 'claude-opus-4.6' }

        Invoke-DpRouteHandler -Name 'models' -Stream $script:responseStream

        (Get-RouteJson).default | Should -Be 'claude-opus-5'
        $script:DeskPilot.DefaultModel | Should -Be 'claude-opus-5'
    }

    It 'falls back to the Engine default when the preferred Model is not advertised' {
        Mock Invoke-DpEngineCommand -ParameterFilter { $Command -eq 'Get-ShpModel' } -MockWith {
            @([pscustomobject]@{ Id = 'claude-opus-4.6'; MaxContextWindowTokens = 200000; ReasoningEfforts = @() })
        }
        Mock Invoke-DpEngineCommand -ParameterFilter { $Command -eq 'Get-ShpDefault' } -MockWith { 'claude-opus-4.6' }

        Invoke-DpRouteHandler -Name 'models' -Stream $script:responseStream

        (Get-RouteJson).default | Should -Be 'claude-opus-4.6'
        $script:DeskPilot.DefaultModel | Should -Be 'claude-opus-4.6'
    }

    It 'still answers when the Engine lists no Models at all' {
        Mock Invoke-DpEngineCommand -ParameterFilter { $Command -eq 'Get-ShpModel' } -MockWith { @() }
        Mock Invoke-DpEngineCommand -ParameterFilter { $Command -eq 'Get-ShpDefault' } -MockWith { $null }

        Invoke-DpRouteHandler -Name 'models' -Stream $script:responseStream

        $response = [System.Text.Encoding]::UTF8.GetString($script:responseStream.ToArray())
        $response | Should -Match '^HTTP/1\.1 200 OK'
        @((Get-RouteJson).models) | Should -BeNullOrEmpty
    }
}

Describe 'default Model reaches the Turn' -Tag 'Unit' {
    It 'seeds the resolved default so a Turn started before /api/models still gets it' {
        $source = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' '..' 'source' 'Public' 'Start-DeskPilot.ps1') -Raw
        $source | Should -Match "PreferredModel\s*=\s*'claude-opus-5'"
        $source | Should -Match "DefaultModel\s*=\s*'claude-opus-5'"
    }

    It 'hands the resolved Model to the Turn instead of only the pinned one' {
        # Passing $Conversation.model here would let a Conversation that pins
        # nothing run on the Engine's default while DeskPilot reports its own.
        $source = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' '..' 'source' 'Private' 'Invoke-DpTurn.ps1') -Raw
        $source | Should -Match 'New-DpTurnParameter[^\r\n]*-Model \$effectiveModelId'
    }
}
