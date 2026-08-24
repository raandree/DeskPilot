#requires -Version 7.0

BeforeAll {
    $privateRoot = Join-Path $PSScriptRoot '..' '..' 'source' 'Private'
    Get-ChildItem -Path $privateRoot -Filter '*.ps1' | ForEach-Object { . $_.FullName }

    # Splits a raw HTTP response into its header text and its body bytes. The body
    # is an image here, so it must never travel through a string.
    function Split-HttpResponse {
        param([byte[]]$Bytes)
        for ($i = 0; $i -lt $Bytes.Length - 3; $i++) {
            if ($Bytes[$i] -eq 13 -and $Bytes[$i + 1] -eq 10 -and $Bytes[$i + 2] -eq 13 -and $Bytes[$i + 3] -eq 10) {
                return @{
                    Head = [System.Text.Encoding]::ASCII.GetString($Bytes, 0, $i)
                    Body = $Bytes[($i + 4)..($Bytes.Length - 1)]
                }
            }
        }
        @{ Head = [System.Text.Encoding]::ASCII.GetString($Bytes); Body = [byte[]]@() }
    }
}

Describe 'fsImage route' -Tag 'Unit' {
    BeforeEach {
        $script:projectRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:projectRoot | Out-Null

        $settings = Get-DpDefaultSettings
        $settings.workspaceFolder = $script:projectRoot
        $script:DeskPilot = @{ Settings = $settings }
        $script:responseStream = [System.IO.MemoryStream]::new()

        $script:gif = [byte[]](([int[]][char[]]'GIF89a') + @(1, 0, 1, 0, 0x80, 0, 0))
        [System.IO.File]::WriteAllBytes((Join-Path $script:projectRoot 'shot.gif'), $script:gif)
    }

    AfterEach {
        $script:responseStream.Dispose()
        $script:DeskPilot = $null
    }

    It 'serves an image with its own media type and byte-for-byte content' {
        Invoke-DpRouteHandler -Name 'fsImage' -Stream $script:responseStream -Request @{ Query = @{ path = 'shot.gif' } }

        $response = Split-HttpResponse -Bytes $script:responseStream.ToArray()
        $response.Head | Should -Match '^HTTP/1\.1 200 OK'
        $response.Head | Should -Match 'Content-Type: image/gif'
        # User content is served here, so the browser must not be allowed to
        # re-interpret it as something it trusts more.
        $response.Head | Should -Match 'X-Content-Type-Options: nosniff'
        [System.BitConverter]::ToString($response.Body) | Should -Be ([System.BitConverter]::ToString($script:gif))
    }

    It 'answers 404 for a file that is not there' {
        Invoke-DpRouteHandler -Name 'fsImage' -Stream $script:responseStream -Request @{ Query = @{ path = 'gone.gif' } }

        $response = [System.Text.Encoding]::UTF8.GetString($script:responseStream.ToArray())
        $response | Should -Match '^HTTP/1\.1 404 Not Found'
        (($response -split "`r`n`r`n", 2)[1] | ConvertFrom-Json).error.code | Should -Be 'not_found'
    }

    It 'refuses a file whose bytes are not an image, whatever it is called' {
        Set-Content -LiteralPath (Join-Path $script:projectRoot 'trap.png') -Value '<script>alert(1)</script>' -NoNewline -Encoding utf8

        Invoke-DpRouteHandler -Name 'fsImage' -Stream $script:responseStream -Request @{ Query = @{ path = 'trap.png' } }

        $response = [System.Text.Encoding]::UTF8.GetString($script:responseStream.ToArray())
        $response | Should -Match '^HTTP/1\.1 400 Bad Request'
        (($response -split "`r`n`r`n", 2)[1] | ConvertFrom-Json).error.code | Should -Be 'not_previewable'
    }

    It 'refuses a path outside the Project folder' {
        $outside = Join-Path $TestDrive 'outside.gif'
        [System.IO.File]::WriteAllBytes($outside, $script:gif)

        Invoke-DpRouteHandler -Name 'fsImage' -Stream $script:responseStream -Request @{ Query = @{ path = $outside } }

        $response = [System.Text.Encoding]::UTF8.GetString($script:responseStream.ToArray())
        $response | Should -Match '^HTTP/1\.1 400 Bad Request'
        (($response -split "`r`n`r`n", 2)[1] | ConvertFrom-Json).error.code | Should -Be 'outside_workspace'
    }

    It 'needs a path' {
        Invoke-DpRouteHandler -Name 'fsImage' -Stream $script:responseStream -Request @{ Query = @{} }

        $response = [System.Text.Encoding]::UTF8.GetString($script:responseStream.ToArray())
        $response | Should -Match '^HTTP/1\.1 400 Bad Request'
        (($response -split "`r`n`r`n", 2)[1] | ConvertFrom-Json).error.code | Should -Be 'no_path'
    }

    It 'needs a Project' {
        $script:DeskPilot.Settings.workspaceFolder = ''

        Invoke-DpRouteHandler -Name 'fsImage' -Stream $script:responseStream -Request @{ Query = @{ path = 'shot.gif' } }

        $response = [System.Text.Encoding]::UTF8.GetString($script:responseStream.ToArray())
        $response | Should -Match '^HTTP/1\.1 400 Bad Request'
        (($response -split "`r`n`r`n", 2)[1] | ConvertFrom-Json).error.code | Should -Be 'no_workspace'
    }
}
