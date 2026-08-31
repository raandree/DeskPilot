#requires -Version 7.0

BeforeAll {
    $privateRoot = Join-Path $PSScriptRoot '..' '..' 'source' 'Private'
    Get-ChildItem -Path $privateRoot -Filter '*.ps1' | ForEach-Object { . $_.FullName }
}

Describe 'Start-DpExternalFile' -Tag 'Unit' {
    BeforeEach {
        $script:projectRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:projectRoot | Out-Null
        Set-Content -LiteralPath (Join-Path $script:projectRoot 'budget.xlsx') -Value 'workbook' -NoNewline
    }

    It 'reports the file it would hand to the associated program' {
        # -WhatIf runs every check and stops short of the launch, so the allowed
        # path is proven without starting a program on the test machine.
        $result = Start-DpExternalFile -Root $script:projectRoot -Path 'budget.xlsx' -WhatIf

        $result.opened | Should -BeTrue
        $result.error | Should -BeNullOrEmpty
        $result.extension | Should -Be '.xlsx'
        $result.name | Should -Be 'budget.xlsx'
        $result.path | Should -Be ([System.IO.Path]::GetFullPath((Join-Path $script:projectRoot 'budget.xlsx')))
    }

    It 'refuses a path outside the Project folder' {
        $outside = Join-Path $TestDrive 'outside.xlsx'
        Set-Content -LiteralPath $outside -Value 'workbook' -NoNewline

        $result = Start-DpExternalFile -Root $script:projectRoot -Path $outside

        $result.code | Should -Be 'outside_workspace'
        $result.opened | Should -BeFalse
    }

    It 'refuses a file that is not there' {
        (Start-DpExternalFile -Root $script:projectRoot -Path 'gone.xlsx').code | Should -Be 'not_found'
    }

    It 'refuses a folder' {
        New-Item -ItemType Directory -Path (Join-Path $script:projectRoot 'docs.xlsx') | Out-Null

        (Start-DpExternalFile -Root $script:projectRoot -Path 'docs.xlsx').code | Should -Be 'not_found'
    }

    It 'needs a Project folder that exists' {
        (Start-DpExternalFile -Root (Join-Path $TestDrive 'nowhere') -Path 'budget.xlsx').code | Should -Be 'no_workspace'
    }

    It 'needs a path' {
        (Start-DpExternalFile -Root $script:projectRoot -Path ' ').code | Should -Be 'no_path'
    }

    It 'refuses <_> outright, because opening it would run it' -ForEach @(
        'payload.exe', 'payload.bat', 'payload.cmd', 'payload.ps1', 'payload.psm1',
        'payload.vbs', 'payload.js', 'payload.hta', 'payload.lnk', 'payload.reg',
        'payload.sh', 'payload.py', 'payload.desktop', 'payload.jar'
    ) {
        Set-Content -LiteralPath (Join-Path $script:projectRoot $_) -Value 'payload' -NoNewline

        $result = Start-DpExternalFile -Root $script:projectRoot -Path $_

        $result.code | Should -Be 'executable'
        $result.opened | Should -BeFalse
    }

    It 'refuses a double extension that ends in an executable one' {
        Set-Content -LiteralPath (Join-Path $script:projectRoot 'budget.xlsx.exe') -Value 'payload' -NoNewline

        (Start-DpExternalFile -Root $script:projectRoot -Path 'budget.xlsx.exe').code | Should -Be 'executable'
    }

    It 'refuses a file with no file type' {
        Set-Content -LiteralPath (Join-Path $script:projectRoot 'LICENSE') -Value 'text' -NoNewline

        (Start-DpExternalFile -Root $script:projectRoot -Path 'LICENSE').code | Should -Be 'no_file_type'
    }

    It 'refuses a file type that is not plain letters and digits' {
        # The allowed shape is what keeps an alternate data stream, a padded name
        # or any other decorated suffix away from the shell.
        Set-Content -LiteralPath (Join-Path $script:projectRoot 'report.a-b') -Value 'text' -NoNewline

        (Start-DpExternalFile -Root $script:projectRoot -Path 'report.a-b').code | Should -Be 'no_file_type'
    }

    It 'matches the file type case-insensitively' {
        Set-Content -LiteralPath (Join-Path $script:projectRoot 'payload.EXE') -Value 'payload' -NoNewline

        (Start-DpExternalFile -Root $script:projectRoot -Path 'payload.EXE').code | Should -Be 'executable'
    }
}

Describe 'fsOpen route' -Tag 'Unit' {
    BeforeEach {
        $script:projectRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:projectRoot | Out-Null
        Set-Content -LiteralPath (Join-Path $script:projectRoot 'budget.xlsx') -Value 'workbook' -NoNewline

        $settings = Get-DpDefaultSettings
        $settings.workspaceFolder = $script:projectRoot
        $script:DeskPilot = @{ Settings = $settings }
        $script:responseStream = [System.IO.MemoryStream]::new()
    }

    AfterEach {
        $script:responseStream.Dispose()
        $script:DeskPilot = $null
    }

    It 'opens a file the operating system has a program for' {
        # Mocked so the gate is proven without a program appearing on the machine
        # running the suite.
        Mock Start-DpExternalFile { @{ path = 'C:\proj\budget.xlsx'; name = 'budget.xlsx'; extension = '.xlsx'; opened = $true; code = $null; error = $null } }

        Invoke-DpRouteHandler -Name 'fsOpen' -Stream $script:responseStream -Body ([pscustomobject]@{ path = 'budget.xlsx' })

        $response = [System.Text.Encoding]::UTF8.GetString($script:responseStream.ToArray())
        $response | Should -Match '^HTTP/1\.1 200 OK'
        $payload = ($response -split "`r`n`r`n", 2)[1] | ConvertFrom-Json
        $payload.opened | Should -BeTrue
        $payload.name | Should -Be 'budget.xlsx'
        Should -Invoke Start-DpExternalFile -Times 1 -Exactly
    }

    It 'answers 403 for a file whose type would run' {
        Set-Content -LiteralPath (Join-Path $script:projectRoot 'payload.exe') -Value 'payload' -NoNewline

        Invoke-DpRouteHandler -Name 'fsOpen' -Stream $script:responseStream -Body ([pscustomobject]@{ path = 'payload.exe' })

        $response = [System.Text.Encoding]::UTF8.GetString($script:responseStream.ToArray())
        $response | Should -Match '^HTTP/1\.1 403 Forbidden'
        (($response -split "`r`n`r`n", 2)[1] | ConvertFrom-Json).error.code | Should -Be 'executable'
    }

    It 'answers 404 for a file that is not there' {
        Invoke-DpRouteHandler -Name 'fsOpen' -Stream $script:responseStream -Body ([pscustomobject]@{ path = 'gone.xlsx' })

        $response = [System.Text.Encoding]::UTF8.GetString($script:responseStream.ToArray())
        $response | Should -Match '^HTTP/1\.1 404 Not Found'
        (($response -split "`r`n`r`n", 2)[1] | ConvertFrom-Json).error.code | Should -Be 'not_found'
    }

    It 'refuses a path outside the Project folder' {
        $outside = Join-Path $TestDrive 'outside.xlsx'
        Set-Content -LiteralPath $outside -Value 'workbook' -NoNewline

        Invoke-DpRouteHandler -Name 'fsOpen' -Stream $script:responseStream -Body ([pscustomobject]@{ path = $outside })

        $response = [System.Text.Encoding]::UTF8.GetString($script:responseStream.ToArray())
        $response | Should -Match '^HTTP/1\.1 400 Bad Request'
        (($response -split "`r`n`r`n", 2)[1] | ConvertFrom-Json).error.code | Should -Be 'outside_workspace'
    }

    It 'needs a path' {
        Invoke-DpRouteHandler -Name 'fsOpen' -Stream $script:responseStream -Body ([pscustomobject]@{})

        $response = [System.Text.Encoding]::UTF8.GetString($script:responseStream.ToArray())
        $response | Should -Match '^HTTP/1\.1 400 Bad Request'
        (($response -split "`r`n`r`n", 2)[1] | ConvertFrom-Json).error.code | Should -Be 'no_path'
    }

    It 'needs a Project' {
        $script:DeskPilot.Settings.workspaceFolder = ''

        Invoke-DpRouteHandler -Name 'fsOpen' -Stream $script:responseStream -Body ([pscustomobject]@{ path = 'budget.xlsx' })

        $response = [System.Text.Encoding]::UTF8.GetString($script:responseStream.ToArray())
        $response | Should -Match '^HTTP/1\.1 400 Bad Request'
        (($response -split "`r`n`r`n", 2)[1] | ConvertFrom-Json).error.code | Should -Be 'no_workspace'
    }
}

Describe 'externalOpenTypes setting' -Tag 'Unit' {
    It 'remembers nothing by default, so DeskPilot asks the first time' {
        @((Get-DpDefaultSettings).externalOpenTypes).Count | Should -Be 0
    }

    It 'normalises a file type to a lowercase dotted extension' {
        $merged = Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch @{ externalOpenTypes = @('XLSX', '.Docx', ' pdf ') }

        $merged.externalOpenTypes | Should -Be @('.xlsx', '.docx', '.pdf')
    }

    It 'keeps one entry per file type' {
        $merged = Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch @{ externalOpenTypes = @('.xlsx', 'xlsx', 'XLSX') }

        @($merged.externalOpenTypes).Count | Should -Be 1
    }

    It 'refuses to remember <_>, which is never opened outside DeskPilot anyway' -ForEach @('.exe', 'ps1', '.SH', '.lnk') {
        { Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch @{ externalOpenTypes = @($_) } } |
            Should -Throw '*never opens*'
    }

    It 'refuses a file type that is not plain letters and digits' {
        { Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch @{ externalOpenTypes = @('.a-b') } } |
            Should -Throw "*Invalid file type*"
    }

    It 'survives a round trip through settings.json' {
        $dataDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dataDir | Out-Null
        $settings = Merge-DpSettings -Current (Get-DpDefaultSettings) -Patch @{ externalOpenTypes = @('.xlsx') }

        Save-DpSettings -Directory $dataDir -Settings $settings
        $loaded = Import-DpSettings -Directory $dataDir

        $loaded.externalOpenTypes | Should -Be @('.xlsx')
    }
}
