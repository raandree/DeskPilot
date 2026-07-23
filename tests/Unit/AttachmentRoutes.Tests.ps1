#requires -Version 7.0

BeforeAll {
    $privateRoot = Join-Path $PSScriptRoot '..' '..' 'source' 'Private'
    Get-ChildItem -Path $privateRoot -Filter '*.ps1' | ForEach-Object { . $_.FullName }
}

Describe 'postMessage image Attachments' -Tag 'Unit' {
    BeforeEach {
        $attachmentRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $attachmentRoot | Out-Null

        $conversation = New-DpConversation -Title 'Attachment test'
        $settings = Get-DpDefaultSettings
        $settings.workspaceFolder = $attachmentRoot
        $script:DeskPilot = @{
            Conversations = @{ $conversation.id = $conversation }
            Settings      = $settings
            TurnRunning   = $false
            Attachments   = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        }
        $script:responseStream = [System.IO.MemoryStream]::new()
        $script:forwardedImages = @()

        Mock Invoke-DpTurn {
            param($Conversation, $Prompt, $Stream, $Image)
            $null = $Conversation, $Prompt, $Stream
            $script:forwardedImages = @($Image)
        }
    }

    AfterEach {
        $script:responseStream.Dispose()
        $script:DeskPilot = $null
    }

    It 'passes an uploaded image Attachment after the selected Project changes' {
        $priorProjectRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $priorProjectRoot | Out-Null
        $imagePath = Join-Path $priorProjectRoot 'clipboard.png'
        Set-Content -LiteralPath $imagePath -Value 'image bytes'
        $script:DeskPilot.Attachments[[System.IO.Path]::GetFullPath($imagePath)] = 'image/png'
        $body = [pscustomobject]@{ prompt = 'Describe this image'; images = @($imagePath) }

        Invoke-DpRouteHandler -Name 'postMessage' -RouteParams @{ id = $conversation.id } -Body $body -Stream $script:responseStream

        $script:forwardedImages | Should -Be @([System.IO.Path]::GetFullPath($imagePath))
        Should -Invoke Invoke-DpTurn -Times 1 -Exactly
    }

    It 'rejects an image path that was not uploaded' {
        $unregisteredPath = Join-Path $TestDrive 'unregistered.png'
        Set-Content -LiteralPath $unregisteredPath -Value 'unregistered'
        $body = [pscustomobject]@{ prompt = 'Describe this image'; images = @($unregisteredPath) }

        Invoke-DpRouteHandler -Name 'postMessage' -RouteParams @{ id = $conversation.id } -Body $body -Stream $script:responseStream

        $response = [System.Text.Encoding]::UTF8.GetString($script:responseStream.ToArray())
        $response | Should -Match '^HTTP/1\.1 400 Bad Request'
        $json = ($response -split "`r`n`r`n", 2)[1] | ConvertFrom-Json
        $json.error.code | Should -Be 'invalid_attachment'
        Should -Invoke Invoke-DpTurn -Times 0 -Exactly
    }

    It 'rejects an uploaded non-image file as a Vision input' {
        $textPath = Join-Path $attachmentRoot 'notes.txt'
        Set-Content -LiteralPath $textPath -Value 'notes'
        $script:DeskPilot.Attachments[[System.IO.Path]::GetFullPath($textPath)] = 'text/plain'
        $body = [pscustomobject]@{ prompt = 'Describe this'; images = @($textPath) }

        Invoke-DpRouteHandler -Name 'postMessage' -RouteParams @{ id = $conversation.id } -Body $body -Stream $script:responseStream

        $response = [System.Text.Encoding]::UTF8.GetString($script:responseStream.ToArray())
        $response | Should -Match '^HTTP/1\.1 400 Bad Request'
        $json = ($response -split "`r`n`r`n", 2)[1] | ConvertFrom-Json
        $json.error.code | Should -Be 'invalid_attachment'
        Should -Invoke Invoke-DpTurn -Times 0 -Exactly
    }

    It 'records uploaded Attachment paths and content types' {
        Mock Get-DpMultipartBoundary { 'test-boundary' }
        Mock Read-DpMultipartParts {
            @([pscustomobject]@{
                    FileName   = 'clipboard.png'
                    Content    = [System.Text.Encoding]::UTF8.GetBytes('image bytes')
                    ContentType = 'image/png'
                })
        }
        $request = @{
            Headers   = @{ 'Content-Type' = 'multipart/form-data; boundary=test-boundary' }
            BodyBytes = [byte[]]@(1)
        }

        Invoke-DpRouteHandler -Name 'uploads' -Request $request -Stream $script:responseStream

        $savedPath = [System.IO.Path]::GetFullPath((Join-Path $attachmentRoot 'clipboard.png'))
        $script:DeskPilot.Attachments.ContainsKey($savedPath) | Should -BeTrue
        $script:DeskPilot.Attachments[$savedPath] | Should -Be 'image/png'
    }
}