#requires -Version 7.0

BeforeAll {
    $privateRoot = Join-Path $PSScriptRoot '..' '..' 'source' 'Private'
    Get-ChildItem -Path $privateRoot -Filter '*.ps1' | ForEach-Object { . $_.FullName }
}

Describe 'gitRestore route' -Tag 'Unit' -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
    BeforeEach {
        $script:repo = Join-Path $TestDrive ('restore-route-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:repo | Out-Null
        & git -C $script:repo init -q 2>$null
        & git -C $script:repo config user.email 'test@example.com' 2>$null
        & git -C $script:repo config user.name 'Test' 2>$null
        & git -C $script:repo config commit.gpgsign false 2>$null
        [System.IO.File]::WriteAllText((Join-Path $script:repo 'tracked.txt'), "one`n")
        & git -C $script:repo add . 2>$null
        & git -C $script:repo commit -q -m 'init' 2>$null
        [System.IO.File]::WriteAllText((Join-Path $script:repo 'tracked.txt'), "one`ntwo`n")

        $script:dataDir = Join-Path $TestDrive ('data-' + [guid]::NewGuid().ToString('N'))
        $script:store = @{ ([System.IO.Path]::GetFullPath($script:repo)) = @(
                @{ rel = 'tracked.txt'; snapshotSha = ''; conversationId = 'c1'; createdAt = '2026-08-06T00:00:00Z' }
            )
        }
        $script:DeskPilot = @{
            Settings = @{ workspaceFolder = $script:repo }
            Changes  = $script:store
            DataDir  = $script:dataDir
        }
        $script:responseStream = [System.IO.MemoryStream]::new()
    }

    AfterEach {
        $script:responseStream.Dispose()
        $script:DeskPilot = $null
    }

    It 'reverts a tracked file to the last commit' {
        $body = [pscustomobject]@{ paths = @('tracked.txt') }
        Invoke-DpRouteHandler -Name 'gitRestore' -Body $body -Stream $script:responseStream

        $response = [System.Text.Encoding]::UTF8.GetString($script:responseStream.ToArray())
        $response | Should -Match '^HTTP/1\.1 200 OK'
        $json = $response -split "`r`n`r`n", 2 | Select-Object -Last 1 | ConvertFrom-Json
        $json.restored | Should -Be @('tracked.txt')
        # Line endings depend on the machine's core.autocrlf, so compare the lines.
        [System.IO.File]::ReadAllText((Join-Path $script:repo 'tracked.txt')) -split '\r?\n' |
            Where-Object { $_ } | Should -Be @('one')
    }

    It 'stops presenting a reverted file as an unreviewed change' {
        $body = [pscustomobject]@{ paths = @('tracked.txt') }
        Invoke-DpRouteHandler -Name 'gitRestore' -Body $body -Stream $script:responseStream

        @(Get-DpChangeEntry -Store $script:store -Root $script:repo) | Should -BeNullOrEmpty
        Test-Path -LiteralPath (Join-Path $script:dataDir 'changes.json') | Should -BeTrue
    }

    It 'keeps a file pending when the restore skipped it' {
        [System.IO.File]::WriteAllText((Join-Path $script:repo 'tracked.txt'), "one`n")
        $body = [pscustomobject]@{ paths = @('tracked.txt') }
        Invoke-DpRouteHandler -Name 'gitRestore' -Body $body -Stream $script:responseStream

        $response = [System.Text.Encoding]::UTF8.GetString($script:responseStream.ToArray())
        $json = $response -split "`r`n`r`n", 2 | Select-Object -Last 1 | ConvertFrom-Json
        $json.skipped.reason | Should -Be 'No changes to undo.'
        @(Get-DpChangeEntry -Store $script:store -Root $script:repo).rel | Should -Be @('tracked.txt')
    }
}
