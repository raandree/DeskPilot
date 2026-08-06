#requires -Version 7.0

BeforeAll {
    $privateRoot = Join-Path $PSScriptRoot '..' '..' 'source' 'Private'
    Get-ChildItem -Path $privateRoot -Filter '*.ps1' | ForEach-Object { . $_.FullName }
}

Describe 'gitCommit route' -Tag 'Unit' -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
    BeforeEach {
        $script:repo = Join-Path $TestDrive ('commit-route-' + [guid]::NewGuid().ToString('N'))
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

    It 'saves every uncommitted file in one commit' {
        $body = [pscustomobject]@{ message = 'Update the report' }
        Invoke-DpRouteHandler -Name 'gitCommit' -Body $body -Stream $script:responseStream

        $response = [System.Text.Encoding]::UTF8.GetString($script:responseStream.ToArray())
        $response | Should -Match '^HTTP/1\.1 200 OK'
        $json = $response -split "`r`n`r`n", 2 | Select-Object -Last 1 | ConvertFrom-Json
        $json.committed | Should -BeTrue
        $json.files | Should -Be @('tracked.txt')
        (Get-DpGitChanges -Root $script:repo).fileCount | Should -Be 0
    }

    It 'stops presenting a committed file as an unreviewed change' {
        $body = [pscustomobject]@{ message = 'Update the report' }
        Invoke-DpRouteHandler -Name 'gitCommit' -Body $body -Stream $script:responseStream

        $response = [System.Text.Encoding]::UTF8.GetString($script:responseStream.ToArray())
        $json = $response -split "`r`n`r`n", 2 | Select-Object -Last 1 | ConvertFrom-Json
        $json.kept | Should -Be 1
        @(Get-DpChangeEntry -Store $script:store -Root $script:repo) | Should -BeNullOrEmpty
        Test-Path -LiteralPath (Join-Path $script:dataDir 'changes.json') | Should -BeTrue
    }

    It 'keeps a still-unreviewed file pending when only one file is committed' {
        [System.IO.File]::WriteAllText((Join-Path $script:repo 'other.txt'), "a`n")
        $script:store[([System.IO.Path]::GetFullPath($script:repo))] += @{ rel = 'other.txt'; snapshotSha = ''; conversationId = 'c1'; createdAt = '2026-08-06T00:00:00Z' }

        $body = [pscustomobject]@{ message = 'Update the report'; paths = @('tracked.txt') }
        Invoke-DpRouteHandler -Name 'gitCommit' -Body $body -Stream $script:responseStream

        @(Get-DpChangeEntry -Store $script:store -Root $script:repo).rel | Should -Be @('other.txt')
    }

    It 'refuses an empty message' {
        $body = [pscustomobject]@{ message = '   ' }
        Invoke-DpRouteHandler -Name 'gitCommit' -Body $body -Stream $script:responseStream

        $response = [System.Text.Encoding]::UTF8.GetString($script:responseStream.ToArray())
        $response | Should -Match '^HTTP/1\.1 400'
        $response | Should -Match 'commit message is required'
        @(Get-DpChangeEntry -Store $script:store -Root $script:repo).rel | Should -Be @('tracked.txt')
    }
}
